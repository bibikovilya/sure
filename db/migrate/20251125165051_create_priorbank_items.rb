class CreatePriorbankItems < ActiveRecord::Migration[7.2]
  def change
    create_table :priorbank_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.string :login
      t.string :password
      t.string :status, default: "good", null: false
      t.boolean :scheduled_for_deletion, default: false, null: false

      t.timestamps
    end
  end
end
