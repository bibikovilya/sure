class PriorbankAccount::TransactionBuilder
  WITHDRAW_PATTERN = "Снятие наличных".freeze

  attr_reader :account

  def initialize(account)
    @account = account
  end

  def build_from_parsed_data(parsed_transactions)
    transactions = []
    transfers = []
    processed_notes = Set.new
    adapter = Account::ProviderImportAdapter.new(account)

    parsed_transactions.each do |data|
      # Skip duplicates using the same logic as TransactionImport
      next if duplicate_exists?(data, adapter) || processed_notes.include?(data[:notes])

      processed_notes.add(data[:notes])

      if atm_withdrawal?(data)
        transfers << build_atm_transfer(data)
      else
        transactions << build_regular_transaction(data)
      end
    end

    { transactions:, transfers: }
  end

  private

    def duplicate_exists?(data, adapter)
      # Reuse TransactionImport's deduplication logic via ProviderImportAdapter
      # This checks for duplicates based on date, amount, currency, and name
      duplicate = adapter.find_duplicate_transaction(
        date: data[:date],
        amount: data[:amount] * -1, # Invert amount for account perspective
        currency: data[:currency],
        name: data[:name]
      )

      # Additional check: if duplicate found, verify notes match exactly
      # This is stronger than the default adapter logic
      duplicate.present? && duplicate.notes == data[:notes]
    end

    def atm_withdrawal?(data)
      data[:notes].to_s.match?(WITHDRAW_PATTERN)
    end

    def build_regular_transaction(data)
      Transaction.new(
        entry: Entry.new(
          account:,
          date: data[:date],
          amount: data[:amount] * -1,
          name: data[:name],
          currency: data[:currency],
          notes: data[:notes]
        )
      )
    end

    def build_atm_transfer(data)
      cash_account = find_or_create_cash_account(data[:currency])
      amount_abs = data[:amount].abs

      # Create transactions separately first to avoid validation issues during Transfer creation
      outflow_entry = Entry.new(
        account:,
        date: data[:date],
        amount: amount_abs,
        currency: data[:currency],
        name: data[:name],
        notes: data[:notes]
      )

      inflow_entry = Entry.new(
        account: cash_account,
        date: data[:date],
        amount: -amount_abs,
        currency: data[:currency],
        name: "Cash from #{account.name}"
      )

      Transfer.new(
        outflow_transaction: Transaction.create!(kind: "funds_movement", entry: outflow_entry),
        inflow_transaction: Transaction.create!(kind: "funds_movement", entry: inflow_entry),
        status: "confirmed"
      )
    end

    def find_or_create_cash_account(currency)
      account_name = "Cash #{currency.upcase}"

      account.family.accounts.find_or_create_by!(name: account_name) do |new_account|
        new_account.balance = 0
        new_account.cash_balance = 0
        new_account.currency = currency
        new_account.accountable = Depository.new
        new_account.classification = "asset"
      end
    end
end
