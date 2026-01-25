class Account::MarketDataImporter
  attr_reader :account

  def initialize(account)
    @account = account
  end

  def import_all
    import_exchange_rates
    import_security_prices
  end

  def import_exchange_rates
    return unless needs_exchange_rates?
    return unless ExchangeRate.provider

    pair_dates = {}

    # 1. ENTRY-BASED PAIRS – currencies that differ from the account currency
    account.entries
           .where.not(currency: account.currency)
           .group(:currency)
           .minimum(:date)
           .each do |source_currency, date|
      key = [ source_currency, account.currency ]
      pair_dates[key] = [ pair_dates[key], date ].compact.min

      inverse_key = [ account.currency, source_currency ]
      pair_dates[inverse_key] = [ pair_dates[inverse_key], date ].compact.min
    end

    # 2. ACCOUNT-BASED PAIR – convert the account currency to the family currency (if different)
    if foreign_account?
      key = [ account.currency, account.family.currency ]
      pair_dates[key] = [ pair_dates[key], account.start_date ].compact.min

      inverse_key = [ account.family.currency, account.currency ]
      pair_dates[inverse_key] = [ pair_dates[inverse_key], account.start_date ].compact.min
    end

    # 3. INTER-ACCOUNT PAIRS – for potential transfer matching between accounts with different currencies
    import_inter_account_exchange_rates(pair_dates)

    pair_dates.each do |(source, target), start_date|
      ExchangeRate.import_provider_rates(
        from: source,
        to: target,
        start_date: start_date,
        end_date: Date.current
      )
    end
  end

  def import_security_prices
    return unless Security.provider

    account_securities = account.trades.map(&:security).uniq

    return if account_securities.empty?

    account_securities.each do |security|
      security.import_provider_prices(
        start_date: first_required_price_date(security),
        end_date: Date.current
      )

      security.import_provider_details
    end
  end

  private
    # Calculates the first date we require a price for the given security scoped to this account
    def first_required_price_date(security)
      account.trades.with_entry
                    .where(security: security)
                    .where(entries: { account_id: account.id })
                    .minimum("entries.date")
    end

    # Adds exchange rate pairs for transfers between accounts with different currencies
    # This ensures that when auto_match_transfers runs, it can find exchange rates
    # between any two account currencies, not just from account currency to family currency
    def import_inter_account_exchange_rates(pair_dates)
      return if account.currency == account.family.currency && !has_multi_currency_entries?

      # Get all other active accounts in the family with different currencies
      other_accounts = account.family.accounts
                              .where(status: [ :draft, :active ])
                              .where.not(id: account.id)
                              .where.not(currency: account.currency)

      # Group by currency to get unique currency pairs
      other_accounts.group_by(&:currency).each do |other_currency, accounts|
        other_start_date = accounts.map(&:start_date).compact.min
        earliest_date = [ account.start_date, other_start_date ].compact.min

        key = [ account.currency, other_currency ]
        pair_dates[key] = [ pair_dates[key], earliest_date ].compact.min

        inverse_key = [ other_currency, account.currency ]
        pair_dates[inverse_key] = [ pair_dates[inverse_key], earliest_date ].compact.min
      end
    end

    def needs_exchange_rates?
      has_multi_currency_entries? || foreign_account?
    end

    def has_multi_currency_entries?
      account.entries.where.not(currency: account.currency).exists?
    end

    def foreign_account?
      account.currency != account.family.currency
    end
end
