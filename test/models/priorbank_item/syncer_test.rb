require "test_helper"

class PriorbankItem::SyncerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
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

  test "download_statements creates a pending Sync record with csv_path for each linked account and enqueues SyncJob" do
    session_double = mock("browser_session")
    csv_path = "/tmp/priorbank_statements_abc/statement.csv"

    downloader_mock = mock("statement_downloader")
    downloader_mock.stubs(:call).returns(csv_path)
    PriorbankAccount::StatementDownloader.stubs(:new).returns(downloader_mock)

    assert_difference -> { @priorbank_account.syncs.where(status: "pending").count }, 1 do
      assert_enqueued_jobs 1, only: SyncJob do
        @syncer.send(:download_statements, session_double, @item_sync)
      end
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
    PriorbankAccount::StatementDownloader.any_instance.stubs(:call) do
      call_count += 1
      if call_count == 1
        raise StandardError, "Download failed"
      else
        csv_path
      end
    end

    # First account (Visa BYN) fails — second account (Visa USD) should still get a sync record
    assert_difference -> { Sync.where(status: "pending").count }, 1 do
      @syncer.send(:download_statements, session_double, @item_sync)
    end

    assert_equal 0, @priorbank_account.syncs.where(status: :pending).count, "failing account must have no pending sync"
    assert_equal 1, second_priorbank_account.syncs.where(status: :pending).count, "succeeding account must have a pending sync"
    assert_equal csv_path, second_priorbank_account.syncs.where(status: :pending).first.data["csv_path"]
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

  # ── perform_post_sync ──────────────────────────────────────────────────────
  # Account sync jobs are enqueued directly in download_statements when each
  # child Sync record is created, so perform_post_sync is intentionally a no-op.

  test "perform_post_sync enqueues no jobs" do
    @priorbank_account.syncs.create!(
      status: :pending,
      data: { "csv_path" => "/tmp/some.csv" }
    )

    assert_no_enqueued_jobs(only: SyncJob) do
      @syncer.perform_post_sync
    end
  end

  # ── download_statements: pending sync deduplication ────────────────────────

  test "download_statements marks pre-existing pending syncs as stale before creating new one" do
    stale_sync = @priorbank_account.syncs.create!(
      status: :pending,
      data: { "csv_path" => "/tmp/old.csv" }
    )

    session_double = mock("browser_session")
    csv_path = "/tmp/priorbank_statements_abc/statement.csv"

    downloader_mock = mock("statement_downloader")
    downloader_mock.stubs(:call).returns(csv_path)
    PriorbankAccount::StatementDownloader.stubs(:new).returns(downloader_mock)

    @syncer.send(:download_statements, session_double, @item_sync)

    stale_sync.reload
    assert_equal "stale", stale_sync.status, "pre-existing pending sync must be marked stale"

    fresh_sync = @priorbank_account.syncs.where(status: :pending).order(created_at: :desc).first
    assert_not_nil fresh_sync
    assert_equal csv_path, fresh_sync.data["csv_path"]
    assert_equal @item_sync.id, fresh_sync.parent_id, "account sync must be parented to item sync"
  end

  test "download_statements stores window dates on the created sync record" do
    session_double = mock("browser_session")
    csv_path = "/tmp/priorbank_statements_abc/statement.csv"

    downloader_mock = mock("statement_downloader")
    downloader_mock.stubs(:call).returns(csv_path)
    PriorbankAccount::StatementDownloader.stubs(:new).returns(downloader_mock)

    @syncer.send(:download_statements, session_double, @item_sync)

    account_sync = @priorbank_account.syncs.where(status: :pending).order(created_at: :desc).first
    window = @priorbank_account.sync_window
    assert_equal window[:start_date], account_sync.window_start_date
    assert_equal window[:end_date], account_sync.window_end_date
  end

  # ── perform_sync (public entry point) ─────────────────────────────────────

  test "perform_sync calls fetch_accounts_from_priorbank and import_accounts without marking sync failed" do
    @syncer.expects(:fetch_accounts_from_priorbank).with(@item_sync).returns([])
    @syncer.expects(:import_accounts).with([], @item_sync)

    @syncer.perform_sync(@item_sync)

    @item_sync.reload
    # Item sync stays in its current state — completion is driven by children finalizing.
    assert_not_equal "failed", @item_sync.status
  end

  test "perform_sync records error and calls mark_failed when an error is raised" do
    @syncer.stubs(:fetch_accounts_from_priorbank).raises(StandardError, "browser crashed")
    @syncer.expects(:mark_failed).with(@item_sync, instance_of(StandardError)).once

    @syncer.perform_sync(@item_sync)
  end

  test "fetch_accounts_from_priorbank calls download_statements and quits session" do
    session_double = mock("browser_session")
    session_double.stubs(:login_and_navigate_to_cards)
    session_double.expects(:quit).once

    Priorbank::BrowserSession.stubs(:new).returns(session_double)

    @syncer.stubs(:extract_card_data).returns([])
    @syncer.expects(:download_statements).once
    @syncer.stubs(:import_accounts)

    @syncer.perform_sync(@item_sync)
  end
end
