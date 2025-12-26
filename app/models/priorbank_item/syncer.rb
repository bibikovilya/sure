class PriorbankItem::Syncer
  attr_reader :priorbank_item

  def initialize(priorbank_item)
    @priorbank_item = priorbank_item
  end

  def perform_sync(sync)
    begin
      fetched_accounts = fetch_accounts_from_priorbank(sync)
      import_accounts(fetched_accounts, sync)

      mark_completed(sync)
    rescue => e
      mark_failed(sync, e)
    end
  end

  def perform_post_sync
    # no-op
  end

  private

    def fetch_accounts_from_priorbank(sync)
      session = nil
      accounts = []

      begin
        sync_update(sync, "browser_init", "Initializing browser...")
        session = Priorbank::BrowserSession.new(
          login: priorbank_item.login,
          password: priorbank_item.password,
          sync: sync,
          headless: true
        )
        session.login_and_navigate_to_cards

        sync_update(sync, "extraction", "Extracting account information...")
        accounts = extract_card_data(session, sync)
        sync_update(sync, "extraction", "Successfully extracted #{accounts.count} accounts", "success")
      rescue => e
        priorbank_item.update!(status: :requires_update)
        raise e
      ensure
        session&.quit
      end

      accounts
    end

    def extract_card_data(session, sync)
      page = session.page
      cards_table = page.at_css("div.bank-cards-list tbody")
      raise "Cards table not found" unless cards_table

      card_rows = cards_table.css("tr")
      accounts = []

      card_rows.each_with_index do |row, index|
        begin
          sync_update(sync, "extraction", "Processing card #{index + 1} of #{card_rows.count}...")

          # Select the card by clicking its checkbox
          checkbox = row.at_css("div.checkbox-cell input")
          next unless checkbox

          # Uncheck any previously selected card
          selected_card = page.at_css("div.bank-cards-list tbody tr div.checkbox-cell input:checked")
          if selected_card
            selected_card.focus
            selected_card.click
          end

          # Select this card
          checkbox.focus
          checkbox.click
          sleep(0.3)

          # Click on "Подробнее" link to open details
          details_link = page.css("ul.nav.nav-pills li.enabled a").find { |link| link.text.strip == "Подробнее" }
          raise "Details link not found" unless details_link

          details_link.click
          sleep(0.5)

          # Extract card details from the details page
          card_data = extract_card_details(session, sync)
          next unless card_data

          accounts << card_data
          sync_update(sync, "extraction", "Extracted card: #{card_data[:name]}")

          # Go back to cards list by clicking the close icon on the active tab
          close_icon = page.at_css("li.k-item.k-state-active i.icon-kendo-tabstrip-close")
          if close_icon
            close_icon.click
            sleep(0.3)
            session.wait_for("div.bank-cards-list", wait: 3, step: 0.3)
          end
        rescue => e
          Rails.logger.warn("[PriorbankItem::Syncer] Failed to extract card #{index + 1}: #{e.message}")
          sync_update(sync, "extraction", "Warning: Failed to extract card #{index + 1}: #{e.message}")
          sleep(5.minutes)

          # Try to navigate back to cards list
          begin
            page.css("span.menu-item-parent").find { |menu| menu.text == "Карты" }.click
            sleep(0.3)
          rescue
            # If we can't go back, we might need to re-navigate
            Rails.logger.warn("[PriorbankItem::Syncer] Failed to navigate back to cards list")
          end
        end
      end

      accounts
    end

    def extract_card_details(session, sync)
      session.wait_for("div.product-details.card-details", wait: 5, step: 0.5)
      details_container = session.page.at_css("div.product-details.card-details")
      return nil unless details_container

      card_data = {}

      # Extract card name from the input field
      name_input = details_container.at_css("input#CardInformation\\.CardName")
      card_data[:name] = name_input["value"] if name_input

      # Extract IBAN
      iban_input = details_container.at_css("input#CardInformation\\.Iban")
      card_data[:account_number] = iban_input["value"] if iban_input

      # Extract account type
      account_type_input = details_container.at_css("input#CardInformation\\.TypeName")
      card_data[:account_type] = account_type_input["value"] if account_type_input

      # Extract balance and currency
      balance_container = details_container.at_css("div.balance div.total-amount")
      if balance_container
        currency_span = balance_container.at_css("span.currency")
        currency_code_span = balance_container.css("span").last

        if currency_span && currency_code_span
          balance_text = currency_span.text.strip
          card_data[:current_balance] = parse_balance(balance_text)
          card_data[:currency] = currency_code_span.text.strip
        end
      end

      # Ensure we have at least a name
      return nil unless card_data[:name].present?

      card_data
    end

    def parse_balance(balance_string)
      # Remove spaces and convert comma to dot
      balance_string.gsub(/\s+/, "").gsub(",", ".").to_f
    rescue
      nil
    end

    def import_accounts(fetched_accounts, sync)
      imported_count = 0
      updated_count = 0
      errors = []

      fetched_accounts.each do |account_data|
        begin
          # Use IBAN as the unique identifier, fallback to name
          find_by_attrs = if account_data[:account_number].present?
            { account_number: account_data[:account_number] }
          else
            { name: account_data[:name] }
          end

          priorbank_account = priorbank_item.priorbank_accounts.find_or_initialize_by(find_by_attrs)

          if priorbank_account.new_record?
            priorbank_account.assign_attributes(
              name: account_data[:name],
              account_type: account_data[:account_type],
              currency: account_data[:currency],
              account_number: account_data[:account_number],
              current_balance: account_data[:current_balance]
            )
            priorbank_account.save!
            imported_count += 1
            sync_update(sync, "import", "Imported account: #{account_data[:name]}")
          else
            priorbank_account.update!(
              name: account_data[:name],
              account_type: account_data[:account_type],
              currency: account_data[:currency],
              account_number: account_data[:account_number],
              current_balance: account_data[:current_balance]
            )
            updated_count += 1
            sync_update(sync, "import", "Updated account: #{account_data[:name]}")
          end
        rescue => e
          error_msg = "Failed to import #{account_data[:name]}: #{e.message}"
          Rails.logger.error("[PriorbankItem::Syncer] #{error_msg}")
          errors << error_msg
          sync_update(sync, "import", error_msg, "error")
          raise e
        end
      end

      stats = {
        "accounts_imported" => imported_count,
        "accounts_updated" => updated_count,
        "accounts_total" => fetched_accounts.count,
        "errors" => errors
      }
      sync.update!(sync_stats: (sync.sync_stats || {}).merge(stats))

      sync_update(sync, "import", "Imported #{imported_count}, updated #{updated_count} accounts", "success")
    end

    def mark_completed(sync)
      sync.complete!
    end

    def mark_failed(sync, error)
      if sync.respond_to?(:status) && sync.status.to_s == "completed"
        Rails.logger.warn("PriorbankItem::Syncer#mark_failed called after completion: #{error.class} - #{error.message}")
        return
      end

      sync.fail!
      sync.update!(error: error.message) if sync.respond_to?(:error)
    end

    def sync_update(sync, step, message, status = "in_progress")
      return unless sync

      Rails.logger.info "[PriorbankItem::Syncer] Step: #{step}, Message: #{message}, Status: #{status}"

      sync.progress_update(step: step, message: message, status: status)
    end
end
