class DropPriorAccounts < ActiveRecord::Migration[7.2]
  def change
    drop_table :prior_accounts do |t|
      t.string :account_number
      t.string :name, null: false
      t.string :currency, null: false
      t.decimal :current_balance, precision: 19, scale: 4
      t.date :last_statement_date
      t.datetime :last_synced_at
      t.jsonb :raw_payload, default: {}
      t.jsonb :raw_transactions_payload, default: {}
      t.jsonb :sync_metadata, default: {}
      t.timestamps

      t.index :name, unique: true
      t.index :account_number, unique: true, where: "account_number IS NOT NULL"
    end
  end
end
