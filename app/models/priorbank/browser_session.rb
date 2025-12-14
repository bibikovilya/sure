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

    sync_update("popup", "Closing popups...")
    close_popup

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

      self.wait_for('//form[contains(@action, "Login")]', wait: 5, step: 0.5)
      form = page.at_xpath('//form[contains(@action, "Login")]')
      login_input = form.at_xpath('.//input[@name="UserName"]')
      password_input = form.at_xpath('.//input[@name="Password"]')
      submit_button = form.at_xpath('.//button[@type="submit"]')

      login_input.focus.type @login
      password_input.focus.type @password

      sync_update("login", "Submitting login form...")
      submit_button.click
      page.network.wait_for_idle

      raise "Failed to login to Priorbank" if page.current_title != "Рабочий стол"

      sync_update("login", "Successfully logged in", "success")
    end

    def close_popup
      until page.css("span.menu-item-parent").find { |menu| menu.text == "Мои продукты" }
        popup = page.at_css("div.k-widget.k-window")
        break unless popup&.visible?

        popup.at_css("span.k-i-close").focus.click
        sync_update("popup", "Closed popup")
        sleep(0.1)
      end
    end

    def open_cards_page
      sync_update("navigation", "Navigating to cards page...")
      page.css("span.menu-item-parent").find { |menu| menu.text == "Мои продукты" }.click
      page.css("span.menu-item-parent").find { |menu| menu.text == "Карты" }.click

      self.wait_for("div.bank-cards-list", init: 1, wait: 5, step: 0.5)

      raise "Failed to open cards page" if page.current_title != "Платежные карточки"

      sync_update("navigation", "Cards page loaded", "success")
    end
end
