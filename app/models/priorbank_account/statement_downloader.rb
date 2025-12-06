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
    session.page.screenshot(path: Rails.root.join("tmp", "prior_fail-#{Time.now.to_i}.png").to_s, full: true)
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

      link = page.at_css("ul.attachments li:last-child a")
      raise "Download link not found" unless link

      link.focus
      page.downloads.wait { link.click }

      sync_update("download_statement", "Statement file downloaded", "success")
    end

    def downloaded_file_path
      files = Dir.glob(File.join(download_path, "*.csv"))
      raise "No CSV file found in download path" if files.empty?

      file_path = files.first
      sync_update("downloaded_file", "Found downloaded file: #{file_path}", "success")

      file_path
    end
end
