require "test_helper"

class PriorbankItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository_byn)
    @priorbank_item = PriorbankItem.create!(
      family: @account.family,
      name: "Test Priorbank",
      login: "testuser",
      password: "testpass"
    )
    @priorbank_account = PriorbankAccount.create!(
      account_type: "Дебетовая карта",
      priorbank_item: @priorbank_item,
      name: "Visa BYN",
      currency: "BYN"
    )
    AccountProvider.create!(
      account: @account,
      provider: @priorbank_account
    )
    @item_sync = Sync.create!(syncable: @priorbank_item)
    @syncer = PriorbankItem::Syncer.new(@priorbank_item)
  end

  # ── download_statements ────────────────────────────────────────────────────

  test "download_statements calls StatementDownloader with per-account sync window and shared session" do
    session_double = mock("browser_session")
    window = @priorbank_account.sync_window

    downloader_mock = mock("statement_downloader")
    downloader_mock.expects(:call).returns("/tmp/priorbank_statements_abc/statement.csv")

    PriorbankAccount::StatementDownloader.expects(:new).with(
      window[:start_date],
      window[:end_date],
      @priorbank_account.name,
      has_entries(session: session_double)
    ).returns(downloader_mock)

    @syncer.send(:download_statements, session_double, @item_sync)
  end

  test "download_statements creates a pending Sync record with csv_path for each linked account" do
    session_double = mock("browser_session")
    csv_path = "/tmp/priorbank_statements_abc/statement.csv"

    downloader_mock = mock("statement_downloader")
    downloader_mock.stubs(:call).returns(csv_path)
    PriorbankAccount::StatementDownloader.stubs(:new).returns(downloader_mock)

    assert_difference -> { @priorbank_account.syncs.where(status: "pending").count }, 1 do
      @syncer.send(:download_statements, session_double, @item_sync)
    end

    account_sync = @priorbank_account.syncs.where(status: "pending").order(created_at: :desc).first
    assert_equal csv_path, account_sync.data["csv_path"]
  end

  test "download_statements continues to next account when one account fails" do
    # Create a second linked priorbank account
    second_account = accounts(:investment)
    second_priorbank_account = PriorbankAccount.create!(
      account_type: "Дебетовая карта",
      priorbank_item: @priorbank_item,
      name: "Visa USD",
      currency: "USD"
    )
    AccountProvider.create!(
      account: second_account,
      provider: second_priorbank_account
    )

    session_double = mock("browser_session")
    csv_path = "/tmp/priorbank_statements_xyz/statement.csv"

    # First account raises, second succeeds
    call_count = 0
    PriorbankAccount::StatementDownloader.any_instance.stubs(:call).with() do
      call_count += 1
      if call_count == 1
        raise StandardError, "Download failed"
      else
        csv_path
      end
    end

    # Should still create a sync record for the second account
    assert_difference -> { Sync.where(status: "pending").count }, 1 do
      @syncer.send(:download_statements, session_double, @item_sync)
    end
  end

  test "download_statements only downloads for accounts with an account_provider (linked accounts)" do
    # Create an unlinked priorbank account (no account_provider)
    unlinked_priorbank_account = PriorbankAccount.create!(
      account_type: "Дебетовая карта",
      priorbank_item: @priorbank_item,
      name: "Unlinked Card",
      currency: "BYN"
    )

    session_double = mock("browser_session")
    csv_path = "/tmp/priorbank_statements_abc/statement.csv"

    downloader_mock = mock("statement_downloader")
    downloader_mock.stubs(:call).returns(csv_path)

    # StatementDownloader should only be called once (for linked account, not unlinked)
    PriorbankAccount::StatementDownloader.expects(:new).once.returns(downloader_mock)

    @syncer.send(:download_statements, session_double, @item_sync)

    # Unlinked account should have no sync records created
    assert_equal 0, unlinked_priorbank_account.syncs.count
  end

  test "download_statements logs warning on per-account failure without aborting" do
    session_double = mock("browser_session")

    PriorbankAccount::StatementDownloader.any_instance.stubs(:call).raises(StandardError, "Network timeout")

    Rails.logger.expects(:warn).with(includes("Visa BYN")).at_least_once

    # Should not raise
    assert_nothing_raised do
      @syncer.send(:download_statements, session_double, @item_sync)
    end
  end

  test "download_statements records progress update for each account" do
    session_double = mock("browser_session")
    csv_path = "/tmp/statement.csv"

    downloader_mock = mock("statement_downloader")
    downloader_mock.stubs(:call).returns(csv_path)
    PriorbankAccount::StatementDownloader.stubs(:new).returns(downloader_mock)

    @syncer.send(:download_statements, session_double, @item_sync)

    @item_sync.reload
    steps = @item_sync.data["steps"].map { |s| s["step"] }
    assert_includes steps, "download_statements"

    download_messages = @item_sync.data["steps"].select { |s| s["step"] == "download_statements" }
    assert download_messages.any? { |s| s["message"].include?("Visa BYN") }
  end
end
