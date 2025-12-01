class RemoveAvailableBalanceFromPriorbankAccounts < ActiveRecord::Migration[7.2]
  def change
    remove_column :priorbank_accounts, :available_balance, :decimal
  end
end
