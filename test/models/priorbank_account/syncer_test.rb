require "test_helper"

class PriorbankAccount::SyncerTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository_byn)
    priorbank_item = PriorbankItem.create!(
      family: @account.family,
      name: "Test Priorbank",
      login: "testuser",
      password: "testpass"
    )
    @priorbank_account = PriorbankAccount.create!(
      account_type: "Дебетовая карта",
      priorbank_item:,
      name: "Visa BYN",
      currency: "BYN"
    )
    @priorbank_account.account_provider = AccountProvider.create!(
      account: @account,
      provider: @priorbank_account
    )
    @sync = Sync.create!(syncable: @priorbank_account)
    @syncer = PriorbankAccount::Syncer.new(@priorbank_account)

    # Common stubs used across tests
    stub_statement_download
    stub_market_data_import
  end

  def stub_statement_download(csv_data = sample_prior_csv)
    PriorbankAccount::StatementDownloader.any_instance.stubs(:call).returns("/tmp/test.csv")
    PriorbankAccount::StatementDownloader.any_instance.stubs(:teardown)
    Utils::CsvEncodingFixer.stubs(:convert_file).returns(csv_data)
  end

  def stub_market_data_import
    Account::MarketDataImporter.any_instance.stubs(:import_all)
  end

  test "perform_sync executes all sync steps successfully" do
    @syncer.perform_sync(@sync)

    @sync.reload
    assert_equal "success", @sync.data["steps"].last["status"]
    assert @sync.sync_stats["imported_transactions"].present?
  end

  test "perform_sync creates transactions from downloaded CSV" do
    assert_difference -> { Transaction.count } => 3 do
      @syncer.perform_sync(@sync)
    end
  end

  test "perform_sync creates transfers for ATM withdrawals" do
    atm_csv = <<~CSV
      Операции по ........5333
      Дата транзакции,Операция,Сумма,Валюта,Дата операции по счету,Комиссия/Money-back,Обороты по счету,Цифровая карта,Категория операции,
      25.03.2024 12:29:59,ATM BLR MINSK PRIORBANK ATM 009  ,"-3 000,00",BYN,25.03.2024,"0,00","-3 000,00",,Снятие наличных,
      Всего по контракту,Зачислено,Списано,Комиссия/Money-back,Изменение баланса,
    CSV

    stub_statement_download(atm_csv)

    assert_difference -> { Transfer.count } => 1,
                      -> { Account.count } => 1 do # Cash account created
      @syncer.perform_sync(@sync)
    end
  end

  test "perform_sync updates sync progress at each step" do
    @syncer.perform_sync(@sync)

    @sync.reload
    progress_steps = @sync.data["steps"].map { |p| p["step"] }

    assert_includes progress_steps, "start"
    assert_includes progress_steps, "fetch_transactions"
    assert_includes progress_steps, "import_transactions"
    assert_includes progress_steps, "market_data"
    assert_includes progress_steps, "balances"
    assert_includes progress_steps, "complete"
  end

  test "perform_sync stores sync stats" do
    @syncer.perform_sync(@sync)

    @sync.reload

    assert_equal 3, @sync.sync_stats["imported_transactions"]
    assert_equal 0, @sync.sync_stats["imported_transfers"]
  end

  test "perform_sync uses custom date window if provided" do
    @sync.update(
      window_start_date: Date.new(2024, 1, 1),
      window_end_date: Date.new(2024, 3, 31)
    )

    downloader_mock = mock()
    downloader_mock.expects(:call).returns("/tmp/test.csv")
    downloader_mock.expects(:teardown)

    PriorbankAccount::StatementDownloader.expects(:new).with(
      Date.new(2024, 1, 1),
      Date.new(2024, 3, 31),
      @priorbank_account.name,
      has_entries(headless: true, sync: @sync, login: "testuser", password: "testpass")
    ).returns(downloader_mock)

    Utils::CsvEncodingFixer.stubs(:convert_file).returns(sample_prior_csv)

    @syncer.perform_sync(@sync)
  end

  test "perform_sync uses default date window if not provided" do
    # Create an existing entry to set the window start
    Entry.create!(
      name: "Existing Transaction",
      account: @account,
      date: Date.new(2024, 1, 15),
      amount: 100,
      currency: "BYN",
      entryable: Transaction.new
    )

    expected_start = Date.new(2024, 1, 15)
    expected_end = Date.new(2024, 4, 15) # 3 months from last entry

    downloader_mock = mock()
    downloader_mock.expects(:call).returns("/tmp/test.csv")
    downloader_mock.expects(:teardown)

    PriorbankAccount::StatementDownloader.expects(:new).with(
      expected_start,
      expected_end,
      @priorbank_account.name,
      has_entries(headless: true, sync: @sync)
    ).returns(downloader_mock)

    Utils::CsvEncodingFixer.stubs(:convert_file).returns(sample_prior_csv)

    @syncer.perform_sync(@sync)
  end

  test "perform_sync handles errors gracefully" do
    PriorbankAccount::StatementDownloader.any_instance.stubs(:call).raises(StandardError.new("Download failed"))

    @syncer.perform_sync(@sync)

    @sync.reload
    error_message = @sync.data["steps"].find { |p| p["status"] == "error" }
    assert error_message.present?
    assert_includes error_message["message"], "Download failed"
  end

  test "perform_sync filters duplicate transactions" do
    # Create existing transaction
    Entry.create!(
      account: @account,
      date: Date.new(2024, 3, 29),
      amount: BigDecimal("29.88"),
      name: "Retail BLR Minsk Gipermarket Gippo",
      currency: "BYN",
      notes: "29.03.2024 19:32:46,Retail BLR Minsk Gipermarket Gippo,-29,88,BYN,29.03.2024,0,00,-29,88,,Магазины продуктовые,",
      entryable: Transaction.new
    )

    # Should only create 2 new transactions (3 total - 1 duplicate)
    assert_difference -> { Transaction.count } => 2 do
      @syncer.perform_sync(@sync)
    end
  end

  test "perform_sync calls market data importer" do
    Account::MarketDataImporter.any_instance.unstub(:import_all)
    Account::MarketDataImporter.any_instance.expects(:import_all).once

    @syncer.perform_sync(@sync)
  end

  test "perform_sync materializes balances for account" do
    Balance::Materializer.any_instance.expects(:materialize_balances).at_least_once

    @syncer.perform_sync(@sync)
  end

  test "perform_sync materializes balances for transfer accounts" do
    atm_csv = <<~CSV
      Операции по ........5333
      Дата транзакции,Операция,Сумма,Валюта,Дата операции по счету,Комиссия/Money-back,Обороты по счету,Цифровая карта,Категория операции,
      25.03.2024 12:29:59,ATM BLR MINSK PRIORBANK ATM 009  ,"-3 000,00",BYN,25.03.2024,"0,00","-3 000,00",,Снятие наличных,
      Всего по контракту,Зачислено,Списано,Комиссия/Money-back,Изменение баланса,
    CSV

    stub_statement_download(atm_csv)

    # Should materialize balances for both main account and created cash account
    Balance::Materializer.any_instance.expects(:materialize_balances).twice

    @syncer.perform_sync(@sync)
  end

  test "perform_post_sync calls auto_match_transfers on family" do
    Family.any_instance.expects(:auto_match_transfers!).once

    @syncer.perform_post_sync
  end

  test "handles CSV encoding issues" do
    # Mock encoding fix
    Utils::CsvEncodingFixer.unstub(:convert_file)
    Utils::CsvEncodingFixer.expects(:convert_file).with("/tmp/test.csv").returns(sample_prior_csv)

    @syncer.perform_sync(@sync)

    @sync.reload
    encoding_messages = @sync.data["steps"].select { |p| p["message"].to_s.include?("encoding") }
    assert encoding_messages.any?
  end

  test "stores intermediate data in sync.data" do
    @syncer.perform_sync(@sync)

    @sync.reload
    assert @sync.data.present?
    assert @sync.data["fixed_csv_data"].present?
    assert @sync.data["parsed_data"].present?
  end

  test "stores window_start_date and window_end_date in sync.data" do
    @syncer.perform_sync(@sync)

    @sync.reload
    assert @sync.data["window_start_date"].present?
    assert @sync.data["window_end_date"].present?
    assert @sync.data["window_start_date"].is_a?(Date)
    assert @sync.data["window_end_date"].is_a?(Date)
    assert @sync.data["window_end_date"] >= @sync.data["window_start_date"]
  end

  private

    def sample_prior_csv
      <<~CSV
        Выписка по контракту
        Период выписки:,01.04.2024-30.06.2024,
        Дата выписки:,17.08.2024 18:50:30,
        Адрес страницы в интернете:,https://www.prior.by/web/Cabinet/BankCards/,
        Номер контракта:,......3670 Валюта контракта BYN,
        Карта:,........0343 VISA VIRTUAL ,
        ФИО:, Илья Бибиков,
        Адрес:,"220000",

        Доступная сумма:,"16,44",
        Заблокировано:,"3,80",
        Кредитный лимит:,"0,00",

        Валюта счета: ,BYN,
        Начальный баланс: ,"37,23"

        Операции по ........9090
        Дата транзакции,Операция,Сумма,Валюта,Дата операции по счету,Комиссия/Money-back,Обороты по счету,Цифровая карта,Категория операции,
        25.03.2024 00:00:00,Поступление на контракт клиента 749114-00081-032913  ,"900,00",BYN,25.03.2024,"0,00","900,00",,,
        Всего по контракту,Зачислено,Списано,Комиссия/Money-back,Изменение баланса,
        ,"628,00","614,89","-10,50","2,61",

        Операции по ........5333
        Дата транзакции,Операция,Сумма,Валюта,Дата операции по счету,Комиссия/Money-back,Обороты по счету,Цифровая карта,Категория операции,
        29.03.2024 19:32:46,Retail BLR Minsk Gipermarket Gippo  ,"-29,88",BYN,29.03.2024,"0,00","-29,88",,Магазины продуктовые,
        29.03.2024 10:48:27,CH Debit BLR MINSK P2P SDBO NO FEE  ,"-50,00",BYN,29.03.2024,"0,00","-50,00",,Переводы с карты на карту,
        Всего по контракту,Зачислено,Списано,Комиссия/Money-back,Изменение баланса,
        ,"628,00","614,89","-10,50","39,84",

        Заблокированные суммы по ........0343
        Дата транзакции,Транзакция,Сумма транзакции,Валюта,Сумма блокировки,Валюта,Цифровая карта,Категория операции,
        15.08.2024 14:51:04,Retail BLR MINSK ROSE CAFE,"14,80",BYN,"14,80",BYN,,Ресторация / бары / кафе,
      CSV
    end
end
