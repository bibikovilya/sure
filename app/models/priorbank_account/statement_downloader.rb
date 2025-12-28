class PriorbankAccount::StatementDownloader
  attr_reader :session, :download_path, :sync
  attr_accessor :start_date, :end_date, :card_name

  def initialize(start_date, end_date, card_name, headless: true, sync: nil, login: nil, password: nil)
    @start_date = start_date
    @end_date = end_date
    @card_name = card_name
    @download_path = Dir.mktmpdir("priorbank_statements_")
    @sync = sync

    login_creds = login || Setting.priorbank_login
    password_creds = password || Setting.priorbank_password
    @session = Priorbank::BrowserSession.new(
      login: login_creds,
      password: password_creds,
      sync: sync,
      headless: headless
    )
  end

  def call
    sync_update("statement_downloader", "Starting statement download...")
    session.login_and_navigate_to_cards
    select_card
    open_statements
    setup_filters
    download_statement
    sleep(1)

    sync_update("statement_downloader", "Statement downloaded successfully!", "success")
    downloaded_file_path
  rescue => e
    capture_error_screenshot(e)
    sync_update("statement_downloader", "Failed to download statement: #{e.message}", "error")
    raise e
  ensure
    session.quit
  end

  def teardown
    FileUtils.rm_rf(download_path) if download_path && Dir.exist?(download_path)
  end

  private

    def page
      session.page
    end

    def sync_update(step, message, status = "in_progress")
      return unless sync

      Rails.logger.info "[PriorbankAccount::StatementDownloader] Sync update - Step: #{step}, Message: #{message}, Status: #{status}"
      sync.progress_update(step: step, message: message, status: status)
    end

    def select_card
      sync_update("select_card", "Start selecting card '#{card_name}'...")
      default_card = page.at_css("div.bank-cards-list tbody tr div.checkbox-cell input:checked")
      default_card.click if default_card

      card_row = page.css("div.bank-cards-list tbody tr").find do |row|
        row.text.include?(card_name)
      end

      raise "Card '#{card_name}' not found" unless card_row

      checkbox = card_row.at_css("div.checkbox-cell input")
      checkbox.focus
      checkbox.click

      sync_update("select_card", "Card '#{card_name}' selected", "success")
    end

    def open_statements
      sync_update("open_statements", "Opening statements...")
      page.css("ul.nav.nav-pills li.enabled a").find { |link| link.attribute("data-link-action") == "history" }.click

      sync_update("open_statements", "Waiting for filters...")
      filters = session.wait_for("div.detailedreport-cards-filter", init: 1, wait: 5, step: 0.5)

      raise "Failed to open statements" unless filters

      sync_update("open_statements", "Statements page loaded", "success")
    end

    def setup_filters
      sync_update("setup_filters", "Setting up date filters...")
      page.css("span.lbl").find { |lbl| lbl.text.strip == "за период" }.click

      sync_update("setup_filters", "Selecting dates #{start_date.strftime('%d.%m.%Y')} - #{end_date.strftime('%d.%m.%Y')}...")
      from = page.xpath("//span[contains(@class, 'k-picker-wrap')]//input")[0]
      to =   page.xpath("//span[contains(@class, 'k-picker-wrap')]//input")[1]

      raise "Can't find datepickers" if !from || !to

      from.focus
      sleep(0.1)
      from.type start_date.strftime("%d%m%Y")
      to.focus
      sleep(0.1)
      to.type end_date.strftime("%d%m%Y")

      sync_update("setup_filters", "Submitting filters...")
      session.wait_for(".bia-filter .row.actions button.btn.btn-primary", init: 1, wait: 5, step: 0.5)
      page.at_css(".bia-filter .row.actions button.btn.btn-primary").click # First click does not work. To lose focus from datepickers probably
      page.at_css(".bia-filter .row.actions button.btn.btn-primary").click

      sync_update("setup_filters", "Waiting for idle...")
      page.network.wait_for_idle
      session.wait_for(".bia-context-element-header", wait: 5, step: 0.5)

      card_header = page.at_css(".bia-context-element-header")
      raise "Card statement not found" unless card_header

      sync_update("setup_filters", "Date filters applied", "success")
    end

    def download_statement
      sync_update("download_statement", "Downloading statement file...")

      page.downloads.set_behavior(save_path: download_path, behavior: :allow)

      max_download_attempts = 5
      download_attempt = 0
      file_found = false

      while download_attempt < max_download_attempts && !file_found
        download_attempt += 1
        sync_update("download_statement", "Download attempt #{download_attempt}/#{max_download_attempts}...")

        attachments = page.css("ul.attachments li a")
        sync_update("download_statement", "Found #{attachments.size} attachment(s)")

        link = attachments.find do |a|
          a.at_css("i.file-icon-csv") || a.attribute("href")&.include?("type=4")
        end

        unless link
          sync_update("download_statement", "CSV download link not found on attempt #{download_attempt}")
          sleep(1)
          next
        end

        sync_update("download_statement", "Clicking CSV download link (attempt #{download_attempt})")

        begin
          link.focus
          sleep(0.2)

          page.downloads.wait(10) do
            link.click
          end

          sync_update("download_statement", "Waiting for file to be written to disk...")

          max_file_wait = 10
          file_wait_attempt = 0

          while file_wait_attempt < max_file_wait && !file_found
            files = Dir.glob(File.join(download_path, "*.csv"))

            if files.any? && File.exist?(files.first) && File.size(files.first) > 0
              file_found = true
              sync_update("download_statement", "File found: #{File.basename(files.first)} (#{File.size(files.first)} bytes)")
            else
              file_wait_attempt += 1
              sleep(0.5)
            end
          end

          break if file_found
          sync_update("download_statement", "File not found after click, retrying...")
        rescue => e
          sync_update("download_statement", "Download attempt #{download_attempt} failed: #{e.message}")
          sleep(1)
        end
      end

      raise "CSV file not found after #{max_download_attempts} download attempts (checked #{download_path})" unless file_found

      sync_update("download_statement", "Statement file downloaded", "success")
    end

    def downloaded_file_path
      files = Dir.glob(File.join(download_path, "*.csv"))
      raise "No CSV file found in download path" if files.empty?

      file_path = files.first
      sync_update("downloaded_file", "Found downloaded file: #{file_path}", "success")

      file_path
    end

    def capture_error_screenshot(error)
      return unless sync

      sync_tmp_dir = Rails.root.join("tmp", "sync", sync.id.to_s)
      FileUtils.mkdir_p(sync_tmp_dir)

      screenshot_path = sync_tmp_dir.join("error_screenshot_#{Time.now.to_i}.png").to_s
      session.page.screenshot(path: screenshot_path, full: true)

      sync.error_screenshot.attach(
        io: File.open(screenshot_path),
        filename: "error_screenshot_#{sync.id}_#{Time.now.to_i}.png",
        content_type: "image/png"
      )

      Rails.logger.info "[PriorbankAccount::StatementDownloader] Error screenshot attached to sync #{sync.id}"
    rescue => screenshot_error
      Rails.logger.error "[PriorbankAccount::StatementDownloader] Failed to attach screenshot: #{screenshot_error.message}"
    end
end
