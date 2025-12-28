class Priorbank::BrowserSession
  LOGIN_PATH = "https://www.prior.by/web/"

  attr_reader :browser, :page, :sync, :login, :password

  def initialize(login:, password:, sync: nil, headless: true)
    @browser = Ferrum::Browser.new(
      timeout: 20,
      process_timeout: 30,
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

    node
  end

  private

    def sync_update(step, message, status = "in_progress")
      return unless sync

      Rails.logger.info "[Priorbank::BrowserSession] Step: #{step}, Message: #{message}, Status: #{status}"
      sync.progress_update(step: step, message: message, status: status)
    end

    def login_to_priorbank
      sync_update("login", "Logging into Priorbank...")
      page.go_to LOGIN_PATH
      page.network.wait_for_idle(timeout: 10)
      sleep(1)

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
      sleep(0.5)

      login_input.focus
      sleep(0.2)
      login_input.type @login
      sleep(0.2)

      login_value = page.evaluate("document.querySelector('input[name=\"UserName\"]').value")
      raise "Login field was not filled properly" if login_value.to_s.empty?
      sync_update("login", "Login field filled: #{login_value.length} characters")

      password_input.focus
      sleep(0.2)
      password_input.type @password
      sleep(0.2)

      password_value = page.evaluate("document.querySelector('input[name=\"Password\"]').value")
      raise "Password field was not filled properly" if password_value.to_s.empty?
      sync_update("login", "Password field filled: #{password_value.length} characters")

      sync_update("login", "Submitting login form...")
      sleep(0.5)
      submit_button.click

      sleep(2)
      page.network.wait_for_idle(timeout: 15)

      current_title = page.current_title
      raise "Failed to login to Priorbank. Current page: '#{current_title}'" if current_title != "Рабочий стол"

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

      # Give an extra moment for JavaScript to settle
      sleep(1)
      page.network.wait_for_idle(timeout: 5) rescue nil

      sync_update("wait_ready", "Page is ready", "success")
    end

    def close_popups
      begin
        popup = page.at_css("div.k-widget.k-window")
        return unless popup

        is_visible = popup.visible? rescue false
        return unless is_visible

        close_button = popup.at_css("span.k-i-close")
        if close_button
          close_button.focus.click
          sync_update("popup", "Closed a popup")
          sleep(0.5)
        else
          sync_update("popup", "No close button found on popup")
        end
      rescue => e
        sync_update("popup", "Error while closing popup: #{e.message}")
      end
    end

    def open_cards_page
      max_attempts = 10
      attempts = 0

      loop do
        attempts += 1
        break if attempts > max_attempts

        begin
          sync_update("navigation", "Navigating to cards page (attempt #{attempts})...")

          close_popups
          sleep(0.5)

          page.css("span.menu-item-parent").find { |menu| menu.text == "Мои продукты" }.click
          sleep(0.3)
          page.css("span.menu-item-parent").find { |menu| menu.text == "Карты" }.click

          self.wait_for("div.bank-cards-list", init: 1, wait: 5, step: 0.5)

          if page.current_title == "Платежные карточки"
            sync_update("navigation", "Cards page loaded", "success")
            return
          end
        rescue => e
          sync_update("navigation", "Attempt #{attempts} failed: #{e.message}")
          sleep(1)
          next if attempts < max_attempts
          raise "Failed to open cards page after #{max_attempts} attempts: #{e.message}"
        end
      end
    end
end
