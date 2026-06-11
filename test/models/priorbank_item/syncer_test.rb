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

  test "perform_post_sync enqueues SyncJob for pending sync records with csv_path" do
    csv_path = "/tmp/priorbank_statements_abc/statement.csv"
    account_sync = @priorbank_account.syncs.create!(
      status: :pending,
      data: { "csv_path" => csv_path }
    )

    assert_enqueued_with(job: SyncJob, args: [ account_sync ]) do
      @syncer.perform_post_sync
    end
  end

  test "perform_post_sync skips accounts without a pending sync with csv_path" do
    # No sync records created for @priorbank_account
    assert_no_enqueued_jobs(only: SyncJob) do
      @syncer.perform_post_sync
    end
  end

  test "perform_post_sync skips pending syncs that have no csv_path in data" do
    # Pending sync but no csv_path in data
    @priorbank_account.syncs.create!(status: :pending, data: { "steps" => [] })

    assert_no_enqueued_jobs(only: SyncJob) do
      @syncer.perform_post_sync
    end
  end

  test "perform_post_sync skips accounts not linked to an app account" do
    unlinked_priorbank_account = PriorbankAccount.create!(
      account_type: "Дебетовая карта",
      priorbank_item: @priorbank_item,
      name: "Unlinked Card",
      currency: "BYN"
    )
    # Create a pending sync with csv_path for the unlinked account
    unlinked_priorbank_account.syncs.create!(
      status: :pending,
      data: { "csv_path" => "/tmp/some.csv" }
    )

    assert_no_enqueued_jobs(only: SyncJob) do
      @syncer.perform_post_sync
    end
  end

  test "perform_post_sync enqueues only the newest pending sync when multiple exist" do
    @priorbank_account.syncs.create!(
      status: :pending,
      data: { "csv_path" => "/tmp/statement_old.csv" }
    )
    newer_sync = @priorbank_account.syncs.create!(
      status: :pending,
      data: { "csv_path" => "/tmp/statement_new.csv" }
    )

    # Only one job should be enqueued (the newest pending sync)
    assert_enqueued_jobs 1, only: SyncJob do
      @syncer.perform_post_sync
    end

    assert_enqueued_with(job: SyncJob, args: [ newer_sync ]) do
      clear_enqueued_jobs
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

  test "perform_sync calls fetch_accounts_from_priorbank and marks sync completed" do
    @syncer.expects(:fetch_accounts_from_priorbank).with(@item_sync).returns([])
    @syncer.expects(:import_accounts).with([], @item_sync)

    @syncer.perform_sync(@item_sync)

    @item_sync.reload
    assert_equal "completed", @item_sync.status
  end

  test "perform_sync marks sync failed when an error is raised" do
    @syncer.stubs(:fetch_accounts_from_priorbank).raises(StandardError, "browser crashed")

    @syncer.perform_sync(@item_sync)

    @item_sync.reload
    assert_equal "failed", @item_sync.status
    assert_includes @item_sync.error, "browser crashed"
  end

  test "fetch_accounts_from_priorbank calls download_statements before session quit" do
    session_double = mock("browser_session")
    session_double.stubs(:login_and_navigate_to_cards)
    session_double.stubs(:quit)

    Priorbank::BrowserSession.stubs(:new).returns(session_double)

    download_called = false
    quit_called = false

    @syncer.stubs(:extract_card_data).returns([])
    @syncer.stubs(:download_statements) do
      raise "download_statements called after quit" if quit_called
      download_called = true
    end
    session_double.stubs(:quit) { quit_called = true }

    @syncer.stubs(:import_accounts)

    @syncer.perform_sync(@item_sync)

    assert download_called, "download_statements must be called"
    assert quit_called, "session.quit must be called"
  end
end
