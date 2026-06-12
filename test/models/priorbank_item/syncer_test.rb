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
    session_double.stubs(:open_cards_page)
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
    session_double.stubs(:open_cards_page)
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
    assert_equal @item_sync.id, account_sync.parent_id, "account sync must be a child of the item sync"
  end

  test "download_statements raises and creates no account syncs when any download fails" do
    second_account = accounts(:investment)
    second_priorbank_account = PriorbankAccount.create!(
      account_type: "Дебетовая карта",
      priorbank_item: @priorbank_item,
      name: "Visa USD",
      currency: "USD"
    )
    AccountProvider.create!(account: second_account, provider: second_priorbank_account)

    session_double = mock("browser_session")
    session_double.stubs(:open_cards_page)

    failing_downloader = mock("failing_downloader")
    failing_downloader.stubs(:call).raises(StandardError, "Download failed")

    PriorbankAccount::StatementDownloader.stubs(:new).with(
      anything, anything, @priorbank_account.name, has_key(:session)
    ).returns(failing_downloader)

    assert_raises(StandardError) do
      @syncer.send(:download_statements, session_double, @item_sync)
    end

    assert_equal 0, @priorbank_account.syncs.where(status: :pending).count
    assert_equal 0, second_priorbank_account.syncs.where(status: :pending).count
  end

  test "download_statements creates no account syncs when first download fails (phase-2 atomicity)" do
    second_account = accounts(:investment)
    second_priorbank_account = PriorbankAccount.create!(
      account_type: "Дебетовая карта",
      priorbank_item: @priorbank_item,
      name: "Visa USD",
      currency: "USD"
    )
    AccountProvider.create!(account: second_account, provider: second_priorbank_account)

    session_double = mock("browser_session")
    session_double.stubs(:open_cards_page)

    # First account fails — second never gets a chance to download
    failing_downloader = mock("failing_downloader")
    failing_downloader.stubs(:call).raises(StandardError, "timeout")
    PriorbankAccount::StatementDownloader.stubs(:new).with(
      anything, anything, @priorbank_account.name, has_key(:session)
    ).returns(failing_downloader)

    assert_no_enqueued_jobs(only: SyncJob) do
      assert_raises(StandardError) do
        @syncer.send(:download_statements, session_double, @item_sync)
      end
    end

    assert_equal 0, Sync.where(syncable: [ @priorbank_account, second_priorbank_account ]).count
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
    session_double.stubs(:open_cards_page)
    csv_path = "/tmp/priorbank_statements_abc/statement.csv"

    downloader_mock = mock("statement_downloader")
    downloader_mock.stubs(:call).returns(csv_path)

    # StatementDownloader should only be called once (for linked account, not unlinked)
    PriorbankAccount::StatementDownloader.expects(:new).once.returns(downloader_mock)

    @syncer.send(:download_statements, session_double, @item_sync)

    # Unlinked account should have no sync records created
    assert_equal 0, unlinked_priorbank_account.syncs.count
  end

  test "download_statements records progress update for each account" do
    session_double = mock("browser_session")
    session_double.stubs(:open_cards_page)
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
    session_double.stubs(:open_cards_page)
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
    session_double.stubs(:open_cards_page)
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

  test "perform_sync completes the item sync after browser work succeeds" do
    @item_sync.start!

    @syncer.expects(:fetch_accounts_from_priorbank).with(@item_sync).returns([])
    @syncer.expects(:import_accounts).with([], @item_sync)

    @syncer.perform_sync(@item_sync)

    assert_equal "completed", @item_sync.reload.status
  end

  test "perform_sync records error and calls mark_failed when an error is raised" do
    @syncer.stubs(:fetch_accounts_from_priorbank).raises(StandardError, "browser crashed")
    @syncer.expects(:mark_failed).with(@item_sync, instance_of(StandardError)).once

    @syncer.perform_sync(@item_sync)
  end

  test "fetch_accounts_from_priorbank calls download_statements and quits session" do
    @item_sync.start!

    session_double = mock("browser_session")
    session_double.stubs(:login)
    session_double.stubs(:open_cards_page)
    session_double.expects(:quit).once

    Priorbank::BrowserSession.stubs(:new).returns(session_double)

    @syncer.stubs(:extract_card_data).returns([])
    @syncer.expects(:download_statements).once
    @syncer.stubs(:import_accounts)

    @syncer.perform_sync(@item_sync)
  end

  test "fetch_accounts_from_priorbank sets requires_update when login fails" do
    session_double = mock("browser_session")
    session_double.stubs(:login).raises(StandardError, "auth failed")
    session_double.stubs(:quit)
    Priorbank::BrowserSession.stubs(:new).returns(session_double)

    assert_raises(StandardError) { @syncer.send(:fetch_accounts_from_priorbank, @item_sync) }

    assert_equal "requires_update", @priorbank_item.reload.status
  end

  test "fetch_accounts_from_priorbank does not set requires_update when login succeeds but download fails" do
    session_double = mock("browser_session")
    session_double.stubs(:login)
    session_double.stubs(:open_cards_page)
    session_double.stubs(:quit)
    Priorbank::BrowserSession.stubs(:new).returns(session_double)

    @syncer.stubs(:extract_card_data).returns([])
    @syncer.stubs(:download_statements).raises(StandardError, "CSV download timeout")

    assert_raises(StandardError) { @syncer.send(:fetch_accounts_from_priorbank, @item_sync) }

    assert_equal "good", @priorbank_item.reload.status
  end
end
