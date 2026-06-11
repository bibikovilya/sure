class Priorbank::BrowserSession
  LOGIN_PATH = "https://www.prior.by/web/"
  BROWSER_TIMEOUT = 30
  PROCESS_TIMEOUT = 60
  POPUP_SELECTORS = [ "div.k-widget.k-window", "div.modal", '[role="dialog"]' ].freeze
  CLOSE_BUTTON_SELECTORS = [ "span.k-i-close", ".k-window-action.k-i-close", "button.close", "[aria-label='Close']", "button[data-dismiss='modal']" ].freeze

  attr_reader :browser, :page, :sync, :login, :password

  def initialize(login:, password:, sync: nil, headless: true)
    @browser = Ferrum::Browser.new(
      timeout: BROWSER_TIMEOUT,
      process_timeout: PROCESS_TIMEOUT,
      headless: headless,
      browser_options: {
        "no-sandbox": nil,
        "disable-dev-shm-usage": nil,
        "disable-gpu": nil
      }
    )
    @page = browser.create_page
    @sync = sync
    @login = login
    @password = password
  end

  def login_and_navigate_to_cards
    login_to_priorbank

    sync_update("wait_ready", "Waiting for page to be fully loaded...")
    wait_for_page_ready

    sync_update("popup", "Closing popups...")
    close_popups

    sync_update("navigation", "Opening cards page...")
    open_cards_page
  end

  def quit
    browser&.quit
  end

  def wait_for(selector, init: nil, wait: 1, step: 0.1, screenshot: false)
    sleep(init) if init
    meth = selector.start_with?("/") ? :at_xpath : :at_css

    if screenshot
      page.screenshot(path: Rails.root.join("tmp", "prior-wait-#{selector.gsub(/[^a-zA-Z0-9]/, '_')}-#{Time.now.to_i}.png").to_s, full: true)
    end

    until node = page.send(meth, selector) rescue nil
      sync_update("wait", "Waiting for: #{selector}")
      if screenshot
        page.screenshot(path: Rails.root.join("tmp", "prior-wait-#{selector.gsub(/[^a-zA-Z0-9]/, '_')}-#{Time.now.to_i}.png").to_s, full: true)
      end
      (wait -= step) > 0 ? sleep(step) : break
    end

    Rails.logger.warn "[Priorbank::BrowserSession] Timed out waiting for selector: #{selector}" unless node
    node
  end

  private

    def screenshot_on_failure(label)
      timestamp = Time.now.to_i
      path = Rails.root.join("tmp", "priorbank-#{label}-#{timestamp}.png").to_s
      page.screenshot(path: path, full: true)
      Rails.logger.info "[Priorbank::BrowserSession] Screenshot saved: #{path}"

      if sync
        sync.error_screenshot.attach(
          io: File.open(path),
          filename: "priorbank-#{label}-#{sync.id}-#{timestamp}.png",
          content_type: "image/png"
        )
      end

      path
    rescue => e
      Rails.logger.warn "[Priorbank::BrowserSession] Failed to save screenshot for '#{label}': #{e.message}"
      nil
    end

    def with_retry(attempts: 3, base_delay: 1)
      attempts.times do |attempt|
        begin
          return yield
        rescue => e
          delay = base_delay * (2**attempt)
          sync_update("retry", "Attempt #{attempt + 1}/#{attempts} failed: #{e.message}. Retrying in #{delay}s...")
          if attempt == attempts - 1
            screenshot_on_failure("retry-failure") if page
            raise
          else
            sleep(delay)
          end
        end
      end
    end

    def sync_update(step, message, status = "in_progress")
      return unless sync

      Rails.logger.info "[Priorbank::BrowserSession] Step: #{step}, Message: #{message}, Status: #{status}"
      sync.progress_update(step: step, message: message, status: status)
    end

    def login_to_priorbank
      sync_update("login", "Logging into Priorbank...")
      page.go_to LOGIN_PATH
      page.network.wait_for_idle(timeout: 10)

      sync_update("login", "Waiting for login form...")
      form = self.wait_for('//form[contains(@action, "Login")]', wait: 10, step: 0.5)
      raise "Login form not found" unless form

      sync_update("login", "Waiting for login fields...")
      login_input = self.wait_for('//input[@name="UserName"]', wait: 5, step: 0.5)
      raise "Login input field not found" unless login_input

      password_input = form.at_xpath('.//input[@name="Password"]')
      raise "Password input field not found" unless password_input

      submit_button = form.at_xpath('.//button[@type="submit"]')
      raise "Submit button not found" unless submit_button

      sync_update("login", "Filling in credentials...")

      login_input.focus
      sleep(0.05)
      login_input.type @login

      login_value = page.evaluate("document.querySelector('input[name=\"UserName\"]').value")
      raise "Login field was not filled properly" if login_value.to_s.empty?
      sync_update("login", "Login field filled: #{login_value.length} characters")

      password_input.focus
      sleep(0.05)
      password_input.type @password

      password_value = page.evaluate("document.querySelector('input[name=\"Password\"]').value")
      raise "Password field was not filled properly" if password_value.to_s.empty?
      sync_update("login", "Password field filled: #{password_value.length} characters")

      sync_update("login", "Submitting login form...")
      submit_button.click

      with_retry(attempts: 5, base_delay: 1) do
        page.network.wait_for_idle(timeout: 15)
        current_title = page.current_title
        raise "Failed to login to Priorbank. Current page: '#{current_title}'" if current_title != "Рабочий стол"
      end

      sync_update("login", "Successfully logged in", "success")
    end

    def wait_for_page_ready
      # Wait for any loading spinners to disappear
      sync_update("wait_ready", "Waiting for spinners to disappear...")

      max_wait = 10 # seconds
      start_time = Time.now

      loop do
        break if Time.now - start_time > max_wait

        # Check if there are any loading indicators
        spinner = page.at_css(".k-loading-mask, .k-loading-image, [class*='loading'], [class*='spinner']") rescue nil
        break unless spinner&.visible? rescue false

        sync_update("wait_ready", "Page still loading...")
        sleep(0.5)
      end

      page.network.wait_for_idle(timeout: 5) rescue nil

      sync_update("wait_ready", "Page is ready", "success")
    end

    def close_popups
      max_iterations = 10
      iterations = 0

      loop do
        break if iterations >= max_iterations
        iterations += 1
        closed_any = false

        POPUP_SELECTORS.each do |selector|
          begin
            popup = page.at_css(selector)
            next unless popup

            # page.evaluate (page-level) dispatches JS click to bypass CDP's
            # "element must be interactive" check that fails on modal overlays.
            # Ferrum::Node has no #evaluate; only Ferrum::Page does.
            closed = page.evaluate(<<~JS)
              (function() {
                var popup = document.querySelector(#{selector.to_json});
                if (!popup) return 0;
                var btns = #{CLOSE_BUTTON_SELECTORS.to_json};
                for (var i = 0; i < btns.length; i++) {
                  var btn = popup.querySelector(btns[i]);
                  if (btn) { btn.click(); return 1; }
                }
                return 0;
              })()
            JS

            if closed > 0
              sync_update("popup", "Closed popup (#{selector})")
              page.network.wait_for_idle(timeout: 3) rescue nil
              closed_any = true
            else
              sync_update("popup", "No close button found on popup (#{selector})")
            end
          rescue => e
            sync_update("popup", "Error while closing popup (#{selector}): #{e.message}")
          end
        end

        break unless closed_any
      end
    end

    def open_cards_page
      with_retry(attempts: 5, base_delay: 1) do
        sync_update("navigation", "Navigating to cards page...")

        close_popups

        page.css("span.menu-item-parent").find { |menu| menu.text == "Мои продукты" }.click
        page.network.wait_for_idle(timeout: 5) rescue nil
        page.css("span.menu-item-parent").find { |menu| menu.text == "Карты" }.click
        page.network.wait_for_idle(timeout: 5) rescue nil

        self.wait_for("div.bank-cards-list", wait: 5, step: 0.5)

        raise "Cards page did not load (title: '#{page.current_title}')" if page.current_title != "Платежные карточки"

        sync_update("navigation", "Cards page loaded", "success")
      end
    end
end
