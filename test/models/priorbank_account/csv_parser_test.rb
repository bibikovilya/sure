require "test_helper"

class PriorbankAccount::CsvParserTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository_byn)
    @parser = PriorbankAccount::CsvParser.new(@account)
  end

  test "extracts transaction lines from complex CSV format" do
    transaction_lines = PriorbankAccount::CsvParser.extract_transaction_lines(sample_prior_csv)

    assert transaction_lines.any?, "Should extract some transaction lines"
    assert_equal 4, transaction_lines.count # 1 header + 3 transaction lines
    assert transaction_lines.first.include?("Дата транзакции"), "First line should be header"
    assert transaction_lines.any? { |line| line.include?("Retail BLR Minsk") }, "Should include transaction line"
  end

  test "parses transaction lines into structured data" do
    result = @parser.parse(sample_prior_csv)

    assert_equal 3, result[:transactions].count
    assert_kind_of Hash, result[:account_details]

    first_transaction = result[:transactions].first
    assert_equal Date.new(2024, 3, 25), first_transaction[:date]
    assert_equal BigDecimal("900"), first_transaction[:amount]
    assert_equal "Поступление на контракт клиента 749114-00081-032913", first_transaction[:name]
    assert_equal "BYN", first_transaction[:currency]
    assert_equal "25.03.2024 00:00:00,Поступление на контракт клиента 749114-00081-032913,900,00,BYN,25.03.2024,0,00,900,00,,,", first_transaction[:notes]
  end

  test "sanitizes numbers with Priorbank format (1.234,56)" do
    csv_with_various_amounts = <<~CSV
      Операции по ........5333
      Дата транзакции,Операция,Сумма,Валюта,Дата операции по счету,Комиссия/Money-back,Обороты по счету,Цифровая карта,Категория операции,
      29.03.2024 19:32:46,Test 1,"-29,88",BYN,29.03.2024,"0,00","-29,88",,Магазины продуктовые,
      29.03.2024 19:32:46,Test 2,"-3 000,00",BYN,29.03.2024,"0,00","-3 000,00",,Снятие наличных,
      29.03.2024 19:32:46,Test 3,"1 234,56",BYN,29.03.2024,"0,00","1 234,56",,Income,
      Всего по контракту,Зачислено,Списано,Комиссия/Money-back,Изменение баланса,
    CSV

    result = @parser.parse(csv_with_various_amounts)

    assert_equal BigDecimal("-29.88"), result[:transactions][0][:amount]
    assert_equal BigDecimal("-3000.00"), result[:transactions][1][:amount]
    assert_equal BigDecimal("1234.56"), result[:transactions][2][:amount]
  end

  test "parses dates with time in Priorbank format" do
    csv_with_dates = <<~CSV
      Операции по ........5333
      Дата транзакции,Операция,Сумма,Валюта,Дата операции по счету,Комиссия/Money-back,Обороты по счету,Цифровая карта,Категория операции,
      29.03.2024 19:32:46,Transaction 1,"100,00",BYN,29.03.2024,"0,00","100,00",,,
      01.01.2024 00:00:00,Transaction 2,"200,00",BYN,01.01.2024,"0,00","200,00",,,
      31.12.2024 23:59:59,Transaction 3,"300,00",BYN,31.12.2024,"0,00","300,00",,,
      Всего по контракту,Зачислено,Списано,Комиссия/Money-back,Изменение баланса,
    CSV

    result = @parser.parse(csv_with_dates)

    assert_equal Date.new(2024, 3, 29), result[:transactions][0][:date]
    assert_equal Date.new(2024, 1, 1), result[:transactions][1][:date]
    assert_equal Date.new(2024, 12, 31), result[:transactions][2][:date]
  end

  test "stores full transaction line in notes for deduplication" do
    result = @parser.parse(sample_prior_csv)

    assert_equal "25.03.2024 00:00:00,Поступление на контракт клиента 749114-00081-032913,900,00,BYN,25.03.2024,0,00,900,00,,,", result[:transactions][0][:notes]
  end

  test "handles empty CSV gracefully" do
    result = @parser.parse("")

    assert_equal 0, result[:transactions].count
    assert_equal 0, result[:blocked_transactions].count
  end

  test "handles CSV with only headers" do
    headers_only = <<~CSV
      Операции по ........5333
      Дата транзакции,Операция,Сумма,Валюта,Дата операции по счету,Комиссия/Money-back,Обороты по счету,Цифровая карта,Категория операции,
      Всего по контракту,Зачислено,Списано,Комиссия/Money-back,Изменение баланса,
    CSV

    result = @parser.parse(headers_only)

    assert_equal 0, result[:transactions].count
  end

  test "handles CSV with multiple account sections" do
    multi_section_csv = <<~CSV
      Операции по ........9090
      Дата транзакции,Операция,Сумма,Валюта,Дата операции по счету,Комиссия/Money-back,Обороты по счету,Цифровая карта,Категория операции,
      25.03.2024 00:00:00,Поступление на контракт клиента,"900,00",BYN,25.03.2024,"0,00","900,00",,,
      Всего по контракту,Зачислено,Списано,Комиссия/Money-back,Изменение баланса,

      Операции по ........5333
      Дата транзакции,Операция,Сумма,Валюта,Дата операции по счету,Комиссия/Money-back,Обороты по счету,Цифровая карта,Категория операции,
      29.03.2024 19:32:46,Retail BLR Minsk,"-29,88",BYN,29.03.2024,"0,00","-29,88",,Магазины продуктовые,
      Всего по контракту,Зачислено,Списано,Комиссия/Money-back,Изменение баланса,
    CSV

    result = @parser.parse(multi_section_csv)

    assert_equal 2, result[:transactions].count
  end

  test "handles malformed amounts gracefully" do
    csv_with_malformed = <<~CSV
      Операции по ........5333
      Дата транзакции,Операция,Сумма,Валюта,Дата операции по счету,Комиссия/Money-back,Обороты по счету,Цифровая карта,Категория операции,
      29.03.2024 19:32:46,Test 1,"",BYN,29.03.2024,"0,00","",,,,
      29.03.2024 19:32:46,Test 2,"invalid",BYN,29.03.2024,"0,00","invalid",,,,
      Всего по контракту,Зачислено,Списано,Комиссия/Money-back,Изменение баланса,
    CSV

    result = @parser.parse(csv_with_malformed)

    assert_equal 2, result[:transactions].count
    assert_equal BigDecimal(0), result[:transactions][0][:amount]
    assert_equal BigDecimal(0), result[:transactions][1][:amount]
  end

  test "handles malformed dates gracefully" do
    csv_with_malformed_dates = <<~CSV
      Операции по ........5333
      Дата транзакции,Операция,Сумма,Валюта,Дата операции по счету,Комиссия/Money-back,Обороты по счету,Цифровая карта,Категория операции,
      invalid,Test 1,"100,00",BYN,29.03.2024,"0,00","100,00",,,
      ,Test 2,"200,00",BYN,29.03.2024,"0,00","200,00",,,
      Всего по контракту,Зачислено,Списано,Комиссия/Money-back,Изменение баланса,
    CSV

    result = @parser.parse(csv_with_malformed_dates)

    # Should default to current date when parsing fails
    assert_equal 2, result[:transactions].count
    assert_equal Date.current, result[:transactions][0][:date]
    assert_equal Date.current, result[:transactions][1][:date]
  end

  test "uses account currency for all transactions" do
    result = @parser.parse(sample_prior_csv)

    result[:transactions].each do |transaction|
      assert_equal @account.currency, transaction[:currency]
    end
  end

  test "handles transactions with money-back fees" do
    csv_with_fees = <<~CSV
      Операции по ........5333
      Дата транзакции,Операция,Сумма,Валюта,Дата операции по счету,Комиссия/Money-back,Обороты по счету,Цифровая карта,Категория операции,
      29.02.2024 19:05:54,Отправка SMS Monthly,"0,00",USD,29.02.2024,"-1,08","-1,08",,,
      Всего по контракту,Зачислено,Списано,Комиссия/Money-back,Изменение баланса,
    CSV

    result = @parser.parse(csv_with_fees)

    assert_equal 1, result[:transactions].count
    assert_equal BigDecimal("-1.08"), result[:transactions][0][:amount]
  end

  test "handles other currency transactions (non-BYN)" do
    csv_with_other_currency = <<~CSV
      Операции по ........5333
      Дата транзакции,Операция,Сумма,Валюта,Дата операции по счету,Комиссия/Money-back,Обороты по счету,Цифровая карта,Категория операции,
      01.11.2025 00:00:00,Retail POL WARSZAWA,"-35,00",PLN,04.11.2025,"0,00","-10,02",,Коммунальные услуги,
      Всего по контракту,Зачислено,Списано,Комиссия/Money-back,Изменение баланса,
    CSV

    result = @parser.parse(csv_with_other_currency)

    assert_equal 1, result[:transactions].count
    # Should use "Обороты по счету" column which has the converted amount
    assert_equal BigDecimal("-10.02"), result[:transactions][0][:amount]
    # Currency should still be account currency (BYN)
    assert_equal "BYN", result[:transactions][0][:currency]
  end

  test "extracts account details from CSV" do
    result = @parser.parse(sample_prior_csv)

    assert_kind_of Hash, result[:account_details]
    assert_equal BigDecimal("16.44"), result[:account_details][:available_amount]
    assert_equal BigDecimal("3.80"), result[:account_details][:blocked_amount]
    assert_equal BigDecimal("0"), result[:account_details][:credit_limit]
  end

  test "handles missing account details gracefully" do
    csv_without_details = <<~CSV
      Операции по ........5333
      Дата транзакции,Операция,Сумма,Валюта,Дата операции по счету,Комиссия/Money-back,Обороты по счету,Цифровая карта,Категория операции,
      29.03.2024 19:32:46,Test,"100,00",BYN,29.03.2024,"0,00","100,00",,,
      Всего по контракту,Зачислено,Списано,Комиссия/Money-back,Изменение баланса,
    CSV

    result = @parser.parse(csv_without_details)

    assert_kind_of Hash, result[:account_details]
    assert_nil result[:account_details][:available_amount]
    assert_nil result[:account_details][:blocked_amount]
    assert_nil result[:account_details][:credit_limit]
  end

  test "extracts blocked transactions section" do
    result = @parser.parse(sample_prior_csv)

    assert_equal 1, result[:blocked_transactions].count

    blocked_tx = result[:blocked_transactions].first
    assert_equal Date.new(2024, 8, 15), blocked_tx[:date]
    assert_equal BigDecimal("14.80"), blocked_tx[:amount]
    assert_equal "Retail BLR MINSK ROSE CAFE", blocked_tx[:name]
    assert_equal "BYN", blocked_tx[:currency]
    assert_equal true, blocked_tx[:blocked]
  end

  test "handles CSV without blocked transactions" do
    csv_without_blocked = <<~CSV
      Операции по ........5333
      Дата транзакции,Операция,Сумма,Валюта,Дата операции по счету,Комиссия/Money-back,Обороты по счету,Цифровая карта,Категория операции,
      29.03.2024 19:32:46,Test,"100,00",BYN,29.03.2024,"0,00","100,00",,,
      Всего по контракту,Зачислено,Списано,Комиссия/Money-back,Изменение баланса,
    CSV

    result = @parser.parse(csv_without_blocked)

    assert_equal 0, result[:blocked_transactions].count
  end

  test "parses multiple blocked transactions" do
    csv_with_multiple_blocked = <<~CSV
      Доступная сумма:,"168,75",
      Заблокировано:,"300,00",
      Кредитный лимит:,"0,00",

      Операции по ........5333
      Дата транзакции,Операция,Сумма,Валюта,Дата операции по счету,Комиссия/Money-back,Обороты по счету,Цифровая карта,Категория операции,
      29.03.2024 19:32:46,Test,"100,00",BYN,29.03.2024,"0,00","100,00",,,
      Всего по контракту,Зачислено,Списано,Комиссия/Money-back,Изменение баланса,

      Заблокированные суммы по ........4714
      Дата транзакции,Транзакция,Сумма транзакции,Валюта,Сумма блокировки,Валюта,Цифровая карта,Категория операции,
      13.12.2025 04:42:20,Retail LVA +37160003355 TICKETSHOP,"156,80",EUR,"156,80",EUR,,Развлечения,
      14.12.2025 10:30:15,Online Payment STEAM,"143,20",EUR,"143,20",EUR,,Цифровые товары,
    CSV

    result = @parser.parse(csv_with_multiple_blocked)

    assert_equal 2, result[:blocked_transactions].count
    assert_equal BigDecimal("156.80"), result[:blocked_transactions][0][:amount]
    assert_equal BigDecimal("143.20"), result[:blocked_transactions][1][:amount]
    assert result[:blocked_transactions].all? { |tx| tx[:blocked] == true }
  end

  test "blocked transactions use correct currency" do
    csv_with_blocked_eur = <<~CSV
      Операции по ........4714
      Дата транзакции,Операция,Сумма,Валюта,Дата операции по счету,Комиссия/Money-back,Обороты по счету,Цифровая карта,Категория операции,
      13.12.2025 16:23:44,CH Payment,"150,00",EUR,13.12.2025,"0,00","150,00",,Поставщик услуг,
      Всего по контракту,Зачислено,Списано,Комиссия/Money-back,Изменение баланса,

      Заблокированные суммы по ........4714
      Дата транзакции,Транзакция,Сумма транзакции,Валюта,Сумма блокировки,Валюта,Цифровая карта,Категория операции,
      13.12.2025 04:42:20,Retail LVA TICKETSHOP,"156,80",EUR,"156,80",EUR,,Развлечения,
    CSV

    result = @parser.parse(csv_with_blocked_eur)

    assert_equal 1, result[:blocked_transactions].count
    assert_equal "EUR", result[:blocked_transactions][0][:currency]
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
