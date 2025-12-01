class AddPriorbankIdAndAccountNumberToPriorbankAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :priorbank_accounts, :account_number, :string
    add_index :priorbank_accounts, :account_number
  end
end
