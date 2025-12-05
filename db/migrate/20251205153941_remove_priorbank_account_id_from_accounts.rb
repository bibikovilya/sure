class RemovePriorbankAccountIdFromAccounts < ActiveRecord::Migration[7.2]
  def change
    remove_column :accounts, :priorbank_account_id, :bigint
  end
end
