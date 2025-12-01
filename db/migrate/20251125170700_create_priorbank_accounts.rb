class CreatePriorbankAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :priorbank_accounts, id: :uuid do |t|
      t.references :priorbank_item, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.string :account_type, null: false
      t.string :currency, default: "BYN", null: false
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :available_balance, precision: 19, scale: 4

      t.timestamps
    end

    add_index :priorbank_accounts, :account_type
    add_index :priorbank_accounts, :currency
  end
end
