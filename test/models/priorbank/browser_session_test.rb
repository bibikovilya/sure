require "test_helper"

class Priorbank::BrowserSessionTest < ActiveSupport::TestCase
  # We test the `with_retry` helper via a lightweight subclass that bypasses
  # the real Ferrum::Browser construction.
  class TestableSession < Priorbank::BrowserSession
    attr_writer :sync

    def initialize
      # Skip real browser initialisation
      @sync = nil
      @login = "test"
      @password = "test"
    end

    # Make private method callable in tests
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
end
