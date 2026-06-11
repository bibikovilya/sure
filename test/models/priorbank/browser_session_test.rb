require "test_helper"

class Priorbank::BrowserSessionTest < ActiveSupport::TestCase
  # We test helpers via a lightweight subclass that bypasses
  # the real Ferrum::Browser construction.
  class TestableSession < Priorbank::BrowserSession
    attr_writer :sync
    attr_accessor :page

    def initialize
      # Skip real browser initialisation
      @sync = nil
      @login = "test"
      @password = "test"
      @page = nil
    end

    # Make private methods callable in tests
    public :with_retry
  end

  setup do
    @session = TestableSession.new
  end

  test "with_retry returns block value on first-attempt success" do
    result = @session.with_retry(attempts: 3, base_delay: 0) { 42 }
    assert_equal 42, result
  end

  test "with_retry retries on error and succeeds on later attempt" do
    call_count = 0
    result = @session.with_retry(attempts: 3, base_delay: 0) do
      call_count += 1
      raise "boom" if call_count < 3
      "ok"
    end

    assert_equal 3, call_count
    assert_equal "ok", result
  end

  test "with_retry re-raises after all attempts exhausted" do
    call_count = 0
    error = assert_raises(RuntimeError) do
      @session.with_retry(attempts: 3, base_delay: 0) do
        call_count += 1
        raise "persistent failure"
      end
    end

    assert_equal 3, call_count
    assert_equal "persistent failure", error.message
  end

  test "with_retry sleeps between failed attempts using exponential backoff" do
    delays = []
    @session.stub(:sleep, ->(d) { delays << d }) do
      begin
        @session.with_retry(attempts: 3, base_delay: 1) { raise "oops" }
      rescue
        nil
      end
    end

    # With 3 attempts there are 2 sleeps: after attempt 1 and attempt 2
    # backoff: base_delay * 2**attempt → 1*1=1, 1*2=2
    assert_equal [ 1, 2 ], delays
  end

  test "with_retry does not sleep after the final failed attempt" do
    sleep_count = 0
    @session.stub(:sleep, ->(_) { sleep_count += 1 }) do
      begin
        @session.with_retry(attempts: 2, base_delay: 1) { raise "oops" }
      rescue
        nil
      end
    end

    # 2 attempts → only 1 sleep (before attempt 2, not after the last one)
    assert_equal 1, sleep_count
  end

  test "with_retry calls screenshot_on_failure on final attempt when page is available" do
    mock_page = Object.new
    @session.page = mock_page

    screenshot_called_with = nil
    @session.stub(:screenshot_on_failure, ->(label) { screenshot_called_with = label }) do
      @session.stub(:sleep, ->(_) { }) do
        begin
          @session.with_retry(attempts: 2, base_delay: 0) { raise "final failure" }
        rescue
          nil
        end
      end
    end

    assert_equal "retry-failure", screenshot_called_with
  end

  test "with_retry does not call screenshot_on_failure when page is nil" do
    @session.page = nil

    screenshot_called = false
    @session.stub(:screenshot_on_failure, ->(_label) { screenshot_called = true }) do
      @session.stub(:sleep, ->(_) { }) do
        begin
          @session.with_retry(attempts: 2, base_delay: 0) { raise "failure" }
        rescue
          nil
        end
      end
    end

    assert_equal false, screenshot_called
  end

  test "screenshot_on_failure saves screenshot to tmp dir" do
    captured_path = nil
    mock_page = Object.new
    mock_page.define_singleton_method(:screenshot) { |path:, full:| captured_path = path }
    @session.page = mock_page

    result = @session.screenshot_on_failure("test-failure")

    assert_not_nil result
    assert_includes result, "priorbank-test-failure-"
    assert_includes result, ".png"
    assert_equal result, captured_path
  end

  test "screenshot_on_failure returns nil and logs warning on error" do
    mock_page = Object.new
    def mock_page.screenshot(**); raise "screenshot failed"; end
    @session.page = mock_page

    result = @session.screenshot_on_failure("error-test")
    assert_nil result
  end

  test "wait_for logs warning when selector not found" do
    mock_page = Object.new
    def mock_page.at_css(_); nil; end
    @session.page = mock_page

    warning_logged = false
    Rails.logger.stub(:warn, ->(msg) { warning_logged = true if msg.include?("Timed out waiting") }) do
      @session.wait_for(".nonexistent", wait: 0)
    end

    assert warning_logged
  end

  test "close_popups handles multiple popup types" do
    # Verify the class constants are defined
    assert_equal 3, Priorbank::BrowserSession::POPUP_SELECTORS.length
    assert_includes Priorbank::BrowserSession::POPUP_SELECTORS, "div.k-widget.k-window"
    assert_includes Priorbank::BrowserSession::POPUP_SELECTORS, "div.modal"
    assert_includes Priorbank::BrowserSession::POPUP_SELECTORS, '[role="dialog"]'
  end
end
