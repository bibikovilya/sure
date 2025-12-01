class RenamePriorAccountIdToPriorbankAccountId < ActiveRecord::Migration[7.2]
  def change
    remove_foreign_key :accounts, :prior_accounts, column: :prior_account_id if foreign_key_exists?(:accounts, :prior_accounts, column: :prior_account_id)

    rename_column :accounts, :prior_account_id, :priorbank_account_id

    add_foreign_key :accounts, :priorbank_accounts, column: :priorbank_account_id
  end
end
