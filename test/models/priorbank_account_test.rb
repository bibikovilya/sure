require "test_helper"

class PriorbankAccountTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository_byn)
    priorbank_item = PriorbankItem.create!(
      family: @account.family,
      name: "Test Priorbank",
      login: "testuser",
      password: "testpass"
    )
    @priorbank_account = PriorbankAccount.create!(
      account_type: "Дебетовая карта",
      priorbank_item:,
      name: "Visa BYN",
      currency: "BYN"
    )
    @priorbank_account.account_provider = AccountProvider.create!(
      account: @account,
      provider: @priorbank_account
    )
  end

  test "sync_window returns 3 months ago as start_date when no syncs and no entries" do
    assert_equal 0, @priorbank_account.syncs.count
    assert_equal 0, @account.entries.count

    window = @priorbank_account.sync_window

    assert_in_delta 3.months.ago.to_date, window[:start_date], 1
    assert_equal Date.current, window[:end_date]
  end

  test "sync_window uses last completed sync window_end_date when available" do
    Sync.create!(
      syncable: @priorbank_account,
      status: "completed",
      window_start_date: Date.new(2024, 1, 1),
      window_end_date: Date.new(2024, 3, 31)
    )

    window = @priorbank_account.sync_window

    assert_equal Date.new(2024, 3, 31), window[:start_date]
    assert_equal Date.current, window[:end_date]
  end

  test "sync_window uses latest entry date when no completed syncs" do
    Entry.create!(
      name: "Existing Transaction",
      account: @account,
      date: Date.new(2024, 1, 15),
      amount: 100,
      currency: "BYN",
      entryable: Transaction.new
    )

    assert_equal 0, @priorbank_account.syncs.where(status: "completed").count

    window = @priorbank_account.sync_window

    assert_equal Date.new(2024, 1, 15), window[:start_date]
    assert_equal Date.current, window[:end_date]
  end

  test "sync_window prefers completed sync over latest entry date" do
    Entry.create!(
      name: "Old Transaction",
      account: @account,
      date: Date.new(2023, 6, 1),
      amount: 50,
      currency: "BYN",
      entryable: Transaction.new
    )
    Sync.create!(
      syncable: @priorbank_account,
      status: "completed",
      window_start_date: Date.new(2024, 1, 1),
      window_end_date: Date.new(2024, 3, 31)
    )

    window = @priorbank_account.sync_window

    assert_equal Date.new(2024, 3, 31), window[:start_date]
  end

  test "sync_window ignores non-completed syncs" do
    Sync.create!(syncable: @priorbank_account, status: "pending")
    Sync.create!(syncable: @priorbank_account, status: "failed")

    window = @priorbank_account.sync_window

    assert_in_delta 3.months.ago.to_date, window[:start_date], 1
  end

  test "sync_window end_date is always Date.current" do
    window = @priorbank_account.sync_window

    assert_equal Date.current, window[:end_date]
  end
end
