require "test_helper"

class PriorbankAccount::TransactionBuilderTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository_byn)
    @builder = PriorbankAccount::TransactionBuilder.new(@account)
  end

  test "builds regular transactions from parsed data" do
    parsed_data = [ regular_transaction_data ]

    result = @builder.build_from_parsed_data(parsed_data)

    assert_equal 1, result[:transactions].count
    assert_equal 0, result[:transfers].count

    transaction = result[:transactions].first
    assert_equal @account, transaction.entry.account
    assert_equal Date.new(2024, 3, 29), transaction.entry.date
    assert_equal BigDecimal("29.88"), transaction.entry.amount # Inverted for account
    assert_equal "Retail BLR Minsk Gipermarket Gippo", transaction.entry.name
    assert_equal "BYN", transaction.entry.currency
    assert_equal "29.03.2024 19:32:46,Retail BLR Minsk Gipermarket Gippo,-29,88,BYN,29.03.2024,0,00,-29,88,,Магазины продуктовые,", transaction.entry.notes
  end

  test "detects ATM withdrawals and creates transfers" do
    parsed_data = [ atm_withdrawal_data ]

    result = @builder.build_from_parsed_data(parsed_data)

    assert_equal 0, result[:transactions].count
    assert_equal 1, result[:transfers].count

    transfer = result[:transfers].first
    assert_equal @account, transfer.outflow_transaction.entry.account
    assert_equal Date.new(2024, 3, 25), transfer.outflow_transaction.entry.date
    assert_equal BigDecimal("3000.00"), transfer.outflow_transaction.entry.amount
    assert_equal "funds_movement", transfer.outflow_transaction.kind
    assert_equal "confirmed", transfer.status
  end

  test "creates cash account for ATM withdrawals" do
    parsed_data = [ atm_withdrawal_data ]

    assert_difference -> { Account.count } => 1 do
      @builder.build_from_parsed_data(parsed_data)
    end

    cash_account = Account.find_by(name: "Cash BYN")
    assert_not_nil cash_account
    assert_equal "BYN", cash_account.currency
    assert_equal "asset", cash_account.classification
    assert_equal 0, cash_account.balance
    assert_equal 0, cash_account.cash_balance
    assert_instance_of Depository, cash_account.accountable
  end

  test "reuses existing cash account for multiple ATM withdrawals" do
    # Create first ATM withdrawal to create cash account
    first_data = [
      {
        date: Date.new(2024, 3, 25),
        amount: BigDecimal("-1000.00"),
        name: "ATM First",
        currency: "BYN",
        notes: "First,Снятие наличных"
      }
    ]

    @builder.build_from_parsed_data(first_data)
    initial_account_count = Account.count

    # Create second ATM withdrawal - should reuse cash account
    second_data = [
      {
        date: Date.new(2024, 3, 26),
        amount: BigDecimal("-2000.00"),
        name: "ATM Second",
        currency: "BYN",
        notes: "Second,Снятие наличных"
      }
    ]

    @builder.build_from_parsed_data(second_data)

    # No new account should be created
    assert_equal initial_account_count, Account.count
  end

  test "creates inflow transaction for ATM transfer to cash account" do
    parsed_data = [ atm_withdrawal_data ]

    result = @builder.build_from_parsed_data(parsed_data)
    transfer = result[:transfers].first

    inflow_entry = transfer.inflow_transaction.entry
    assert_equal "Cash BYN", inflow_entry.account.name
    assert_equal Date.new(2024, 3, 25), inflow_entry.date
    assert_equal BigDecimal("-3000.00"), inflow_entry.amount # Negative for inflow
    assert_equal "Cash from Local Account", inflow_entry.name
    assert_equal "BYN", inflow_entry.currency
    assert_equal "funds_movement", transfer.inflow_transaction.kind
  end

  test "handles mixed regular transactions and ATM transfers" do
    parsed_data = [
      regular_transaction_data,
      atm_withdrawal_data,
      {
        date: Date.new(2024, 3, 27),
        amount: BigDecimal("-1000.00"),
        name: "ATM BLR MINSK PRIORBANK ATM 009",
        currency: "BYN",
        notes: "27.03.2024 12:29:59,ATM BLR MINSK PRIORBANK ATM 009,-1 000,00,BYN,27.03.2024,0,00,-1 000,00,,Снятие наличных,"
      }
    ]

    result = @builder.build_from_parsed_data(parsed_data)

    assert_equal 1, result[:transactions].count
    assert_equal 2, result[:transfers].count
  end

  test "filters out duplicate transactions based on existing entries" do
    # Create an existing transaction
    Entry.create!(
      account: @account,
      date: Date.new(2024, 3, 29),
      amount: BigDecimal("29.88"),
      name: "Retail BLR Minsk Gipermarket Gippo",
      currency: "BYN",
      notes: "29.03.2024 19:32:46,Retail BLR Minsk Gipermarket Gippo,-29,88,BYN,29.03.2024,0,00,-29,88,,Магазины продуктовые,",
      entryable: Transaction.new
    )

    # Try to create duplicate
    parsed_data = [ regular_transaction_data ]

    result = @builder.build_from_parsed_data(parsed_data)

    assert_equal 0, result[:transactions].count
    assert_equal 0, result[:transfers].count
  end

  test "does not filter transactions with different notes" do
    # Create an existing transaction with different notes
    Entry.create!(
      account: @account,
      date: Date.new(2024, 3, 29),
      amount: BigDecimal("29.88"),
      name: "Retail BLR Minsk Gipermarket Gippo",
      currency: "BYN",
      notes: "different,notes",
      entryable: Transaction.new
    )

    # Try to create transaction with same details but different notes
    parsed_data = [ regular_transaction_data ]

    result = @builder.build_from_parsed_data(parsed_data)

    # Should create new transaction because notes differ
    assert_equal 1, result[:transactions].count
  end

  test "filters duplicates with trailing spaces in notes" do
    # Create an existing transaction with trailing spaces in notes
    # This simulates old data that wasn't normalized
    Entry.create!(
      account: @account,
      date: Date.new(2024, 10, 2),
      amount: BigDecimal("8.00"),
      name: "Retail HKG Hong Kong SmartGlocal",
      currency: "EUR",
      notes: "02.10.2025 00:00:00,Retail HKG Hong Kong SmartGlocal  ,-8,00,EUR,03.10.2025,0,00,-8,00,,Цифровые товары,",
      entryable: Transaction.new
    )

    # Try to create same transaction but with normalized notes (no trailing spaces)
    parsed_data = [
      {
        date: Date.new(2024, 10, 2),
        amount: BigDecimal("-8.00"),
        name: "Retail HKG Hong Kong SmartGlocal",
        currency: "EUR",
        notes: "02.10.2025 00:00:00,Retail HKG Hong Kong SmartGlocal,-8,00,EUR,03.10.2025,0,00,-8,00,,Цифровые товары,"
      }
    ]

    result = @builder.build_from_parsed_data(parsed_data)

    # Should filter as duplicate despite trailing space difference
    assert_equal 0, result[:transactions].count
  end

  test "prevents duplicate processing within same batch" do
    parsed_data = [
      regular_transaction_data,
      regular_transaction_data # Duplicate in same batch
    ]

    result = @builder.build_from_parsed_data(parsed_data)

    # Should only create one transaction
    assert_equal 1, result[:transactions].count
  end

  test "inverts amount sign for account entries" do
    parsed_data = [
      {
        date: Date.new(2024, 3, 29),
        amount: BigDecimal("-29.88"),  # Negative in CSV (expense)
        name: "Expense",
        currency: "BYN",
        notes: "expense"
      },
      {
        date: Date.new(2024, 3, 29),
        amount: BigDecimal("900.00"),  # Positive in CSV (income)
        name: "Income",
        currency: "BYN",
        notes: "income"
      }
    ]

    result = @builder.build_from_parsed_data(parsed_data)

    expense_entry = result[:transactions].find { |t| t.entry.name == "Expense" }.entry
    income_entry = result[:transactions].find { |t| t.entry.name == "Income" }.entry

    # Signs should be inverted
    assert_equal BigDecimal("29.88"), expense_entry.amount
    assert_equal BigDecimal("-900.00"), income_entry.amount
  end

  test "handles zero amount transactions" do
    parsed_data = [
      {
        date: Date.new(2024, 3, 29),
        amount: BigDecimal("0"),
        name: "Zero amount transaction",
        currency: "BYN",
        notes: "zero"
      }
    ]

    result = @builder.build_from_parsed_data(parsed_data)

    assert_equal 1, result[:transactions].count
    assert_equal BigDecimal("0"), result[:transactions].first.entry.amount
  end

  test "handles money-back fees correctly" do
    parsed_data = [
      {
        date: Date.new(2024, 2, 29),
        amount: BigDecimal("-1.08"),
        name: "SMS service fee",
        currency: "BYN",
        notes: "fee,with,moneyback"
      }
    ]

    result = @builder.build_from_parsed_data(parsed_data)

    assert_equal 1, result[:transactions].count
    transaction = result[:transactions].first
    assert_equal BigDecimal("1.08"), transaction.entry.amount
  end

  test "handles other currency transactions" do
    parsed_data = [
      {
        date: Date.new(2025, 11, 1),
        amount: BigDecimal("-10.02"),  # Converted amount in account currency
        name: "Retail POL WARSZAWA ORANGE FLEX",
        currency: "BYN",  # Account currency
        notes: "transaction,in,PLN"
      }
    ]

    result = @builder.build_from_parsed_data(parsed_data)

    assert_equal 1, result[:transactions].count
    transaction = result[:transactions].first
    assert_equal BigDecimal("10.02"), transaction.entry.amount
    assert_equal "BYN", transaction.entry.currency
  end

  test "handles empty parsed data" do
    result = @builder.build_from_parsed_data([])

    assert_equal 0, result[:transactions].count
    assert_equal 0, result[:transfers].count
  end

  test "returns duplicates in separate field" do
    # Create an existing transaction
    Entry.create!(
      account: @account,
      date: Date.new(2024, 3, 29),
      amount: BigDecimal("29.88"),
      name: "Retail BLR Minsk Gipermarket Gippo",
      currency: "BYN",
      notes: "29.03.2024 19:32:46,Retail BLR Minsk Gipermarket Gippo,-29,88,BYN,29.03.2024,0,00,-29,88,,Магазины продуктовые,",
      entryable: Transaction.new
    )

    # Parse data with duplicate and new transaction
    parsed_data = [
      regular_transaction_data,  # Duplicate
      {
        date: Date.new(2024, 3, 30),
        amount: BigDecimal("-50.00"),
        name: "New transaction",
        currency: "BYN",
        notes: "new,transaction,notes"
      }
    ]

    result = @builder.build_from_parsed_data(parsed_data)

    # Should have 1 new transaction, 0 transfers, and 1 duplicate
    assert_equal 1, result[:transactions].count
    assert_equal 0, result[:transfers].count
    assert_equal 1, result[:duplicates].count

    # Verify duplicate contains correct data
    duplicate = result[:duplicates].first
    assert_equal Date.new(2024, 3, 29), duplicate[:date]
    assert_equal BigDecimal("-29.88"), duplicate[:amount]
    assert_equal "Retail BLR Minsk Gipermarket Gippo", duplicate[:name]
  end

  test "returns multiple duplicates when batch contains multiple existing transactions" do
    # Create two existing transactions
    Entry.create!(
      account: @account,
      date: Date.new(2024, 3, 29),
      amount: BigDecimal("29.88"),
      name: "Retail BLR Minsk Gipermarket Gippo",
      currency: "BYN",
      notes: "29.03.2024 19:32:46,Retail BLR Minsk Gipermarket Gippo,-29,88,BYN,29.03.2024,0,00,-29,88,,Магазины продуктовые,",
      entryable: Transaction.new
    )

    Entry.create!(
      account: @account,
      date: Date.new(2024, 3, 25),
      amount: BigDecimal("3000.00"),
      name: "ATM BLR MINSK PRIORBANK ATM 009",
      currency: "BYN",
      notes: "25.03.2024 12:29:59,ATM BLR MINSK PRIORBANK ATM 009,-3 000,00,BYN,25.03.2024,0,00,-3 000,00,,Снятие наличных,",
      entryable: Transaction.new
    )

    # Parse data with both duplicates and a new transaction
    parsed_data = [
      regular_transaction_data,  # Duplicate 1
      atm_withdrawal_data,       # Duplicate 2
      {
        date: Date.new(2024, 3, 30),
        amount: BigDecimal("-100.00"),
        name: "New purchase",
        currency: "BYN",
        notes: "new,purchase,notes"
      }
    ]

    result = @builder.build_from_parsed_data(parsed_data)

    assert_equal 1, result[:transactions].count
    assert_equal 0, result[:transfers].count
    assert_equal 2, result[:duplicates].count

    # Verify both duplicates are present
    duplicate_names = result[:duplicates].map { |d| d[:name] }
    assert_includes duplicate_names, "Retail BLR Minsk Gipermarket Gippo"
    assert_includes duplicate_names, "ATM BLR MINSK PRIORBANK ATM 009"
  end

  test "returns in-batch duplicates in duplicates field" do
    parsed_data = [
      regular_transaction_data,
      regular_transaction_data  # Same transaction twice in batch
    ]

    result = @builder.build_from_parsed_data(parsed_data)

    # First one processed, second one marked as duplicate
    assert_equal 1, result[:transactions].count
    assert_equal 0, result[:transfers].count
    assert_equal 1, result[:duplicates].count
  end

  private

    def regular_transaction_data
      {
        date: Date.new(2024, 3, 29),
        amount: BigDecimal("-29.88"),
        name: "Retail BLR Minsk Gipermarket Gippo",
        currency: "BYN",
        notes: "29.03.2024 19:32:46,Retail BLR Minsk Gipermarket Gippo,-29,88,BYN,29.03.2024,0,00,-29,88,,Магазины продуктовые,"
      }
    end

    def atm_withdrawal_data
      {
        date: Date.new(2024, 3, 25),
        amount: BigDecimal("-3000.00"),
        name: "ATM BLR MINSK PRIORBANK ATM 009",
        currency: "BYN",
        notes: "25.03.2024 12:29:59,ATM BLR MINSK PRIORBANK ATM 009,-3 000,00,BYN,25.03.2024,0,00,-3 000,00,,Снятие наличных,"
      }
    end
end
