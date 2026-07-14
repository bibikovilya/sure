require "test_helper"

class PriorbankAccount::StatementDownloaderTest < ActiveSupport::TestCase
  setup do
    @start_date = Date.new(2024, 1, 1)
    @end_date = Date.new(2024, 3, 31)
    @card_name = "Visa BYN"
  end

  # ── injected-session path ──────────────────────────────────────────────────

  test "does not call login_and_navigate_to_cards when session is injected" do
    session_double = mock("browser_session")
    session_double.expects(:login_and_navigate_to_cards).never
    session_double.expects(:quit).never

    downloader = PriorbankAccount::StatementDownloader.new(
      @start_date, @end_date, @card_name, session: session_double
    )

    # Stub the card-specific steps so they don't try real browser calls
    downloader.stubs(:select_card)
    downloader.stubs(:open_statements)
    downloader.stubs(:setup_filters)
    downloader.stubs(:download_statement)
    downloader.stubs(:downloaded_file_path).returns("/tmp/test.csv")

    result = downloader.call
    assert_equal "/tmp/test.csv", result
  end

  test "does not call session.quit when injected session call raises an error" do
    session_double = mock("browser_session")
    session_double.expects(:quit).never

    downloader = PriorbankAccount::StatementDownloader.new(
      @start_date, @end_date, @card_name, session: session_double
    )

    downloader.stubs(:select_card).raises(StandardError, "card not found")
    downloader.stubs(:open_statements)
    downloader.stubs(:setup_filters)
    downloader.stubs(:download_statement)
    downloader.stubs(:capture_error_screenshot)

    assert_raises(StandardError) { downloader.call }
  end

  test "uses the injected session as its own session" do
    session_double = mock("browser_session")

    downloader = PriorbankAccount::StatementDownloader.new(
      @start_date, @end_date, @card_name, session: session_double
    )

    assert_equal session_double, downloader.session
  end

  # ── self-owned session path (backward-compat) ─────────────────────────────

  test "creates its own BrowserSession and calls login when no session injected" do
    browser_session_mock = mock("owned_browser_session")
    browser_session_mock.expects(:login_and_navigate_to_cards).once
    browser_session_mock.expects(:quit).once

    Priorbank::BrowserSession.expects(:new).with(
      has_entries(login: "testlogin", password: "testpass")
    ).returns(browser_session_mock)

    downloader = PriorbankAccount::StatementDownloader.new(
      @start_date, @end_date, @card_name, login: "testlogin", password: "testpass"
    )

    downloader.stubs(:select_card)
    downloader.stubs(:open_statements)
    downloader.stubs(:setup_filters)
    downloader.stubs(:download_statement)
    downloader.stubs(:downloaded_file_path).returns("/tmp/test.csv")

    downloader.call
  end

  test "calls session.quit when self-owned session raises an error" do
    browser_session_mock = mock("owned_browser_session")
    browser_session_mock.stubs(:login_and_navigate_to_cards)
    browser_session_mock.expects(:quit).once

    Priorbank::BrowserSession.stubs(:new).returns(browser_session_mock)

    downloader = PriorbankAccount::StatementDownloader.new(
      @start_date, @end_date, @card_name, login: "l", password: "p"
    )

    downloader.stubs(:select_card).raises(StandardError, "select failed")
    downloader.stubs(:capture_error_screenshot)

    assert_raises(StandardError) { downloader.call }
  end
end
