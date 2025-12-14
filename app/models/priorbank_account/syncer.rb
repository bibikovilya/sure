class PriorbankAccount::Syncer
  attr_reader :account, :priorbank_account, :sync

  def initialize(priorbank_account)
    @priorbank_account = priorbank_account
    @account = priorbank_account.account
  end

  def perform_sync(sync)
    @sync = sync
    sync_step_update("start", "Starting Priorbank account #{account.id} - #{account.name} sync...")

    csv_data = fetch_transactions
    parsed_data = parse_csv(csv_data)
    records = build_transactions(parsed_data)
    transactions, transfers = import_transactions(records)

    import_market_data
    materialize_balances(transfers)

    sync.update(sync_stats: { imported_transactions: transactions.ids.count, imported_transfers: transfers.ids.count })

    sync_step_update("complete", "Sync completed successfully!", "success")
  rescue => e
    sync_step_update("complete", "Sync failed: #{e.message}", "error")
    raise e
  end

  def perform_post_sync
    account.family.auto_match_transfers!
  end

  private

    def sync_step_update(step, message, status = "in_progress")
      Rails.logger.info "[PriorbankAccount::Syncer] Sync update - Step: #{step}, Message: #{message}, Status: #{status}"
      sync.progress_update(step: step, message: message, status: status)
    end

    def sync_data_update(key, value)
      data = sync.data || {}
      data[key] = value
      sync.update(data: data)
    end

    def fetch_transactions
      window_start = sync.window_start_date || account.entries.maximum(:date) || 3.months.ago.to_date
      window_end = sync.window_end_date || [ window_start + 3.months, Date.current ].min
      sync_data_update("window_start_date", window_start)
      sync_data_update("window_end_date", window_end)

      sync_step_update("fetch_transactions", "Fetching transactions from #{window_start.strftime('%d.%m.%Y')} to #{window_end.strftime('%d.%m.%Y')}...")

      downloader = PriorbankAccount::StatementDownloader.new(
        window_start,
        window_end,
        priorbank_account.name,
        headless: true,
        sync: sync,
        login: priorbank_account.login,
        password: priorbank_account.password
      )
      csv_file_path = downloader.call

      sync_step_update("fetch_transactions", "Fixing the downloaded file encoding #{csv_file_path}...")
      fixed_csv_data = Utils::CsvEncodingFixer.convert_file(csv_file_path)
      sync_step_update("fetch_transactions", "Downloaded file encoding fixed", "success")
      sync_data_update("fixed_csv_data", fixed_csv_data)

      downloader.teardown
      fixed_csv_data
    rescue => e
      sync_step_update("fetch_transactions", "Error fetching transactions: #{e.message}", "error")
      raise
    end

    def parse_csv(csv_data)
      sync_step_update("import_transactions", "Parsing transactions...")
      parsed_data = PriorbankAccount::CsvParser.new(account).parse(csv_data)
      sync_step_update("import_transactions", "Found #{parsed_data.count} transactions")
      sync_data_update("parsed_data", parsed_data)
      parsed_data
    rescue => e
      sync_step_update("import_transactions", "Error parsing transactions: #{e.message}", "error")
      raise
    end

    def build_transactions(parsed_data)
      sync_step_update("import_transactions", "Building transactions...")
      records = PriorbankAccount::TransactionBuilder.new(account).build_from_parsed_data(parsed_data)
      sync_step_update("import_transactions", "Built #{records[:transactions].count} transactions and #{records[:transfers].count} transfers")
      sync_data_update("built_entries", records[:transactions].map { it.entry })
      sync_data_update("built_transfers", records[:transfers].map { |it| [ it.outflow_transaction.entry, it.inflow_transaction.entry ] }.flatten)
      records
    rescue => e
      sync_step_update("import_transactions", "Error building transactions: #{e.message}", "error")
      raise
    end

    def import_transactions(records)
      sync_step_update("import_transactions", "Saving to database...")
      transactions = Transaction.import!(records[:transactions], recursive: true)
      transfers = Transfer.import!(records[:transfers], recursive: true)
      sync_step_update("import_transactions", "Successfully imported transactions and transfers", "success")
      sync_data_update("imported_transactions", transactions)
      sync_data_update("imported_transfers", transfers)

      [ transactions, transfers ]
    rescue => e
      sync_step_update("import_transactions", "Error importing transactions: #{e.message}", "error")
      raise
    end

    def import_market_data
      sync_step_update("market_data", "Importing market data...")
      Account::MarketDataImporter.new(account).import_all
      sync_step_update("market_data", "Market data imported", "success")
    rescue => e
      sync_step_update("market_data", "Error syncing market data for account #{account.id}: #{e.message}", "error")
      Sentry.capture_exception(e)
    end

    def materialize_balances(transfers)
      sync_step_update("balances", "Calculating balances...")
      strategy = account.linked? ? :reverse : :forward
      Balance::Materializer.new(account, strategy: strategy).materialize_balances

      sync_step_update("balances", "Calculating balances for transfers...")
      Transfer.where(id: transfers.ids).each do |transfer|
        Balance::Materializer.new(transfer.inflow_transaction.entry.account, strategy: :forward).materialize_balances
      end
      sync_step_update("balances", "Balances calculated", "success")
    rescue => e
      sync_step_update("balances", "Error materializing balances for account #{account.id}: #{e.message}", "error")
      raise
    end
end
