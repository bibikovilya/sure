class RenameTransactionPriorImportType < ActiveRecord::Migration[8.1]
  def up
    Import.where(type: "TransactionPriorImport").update_all(type: "TransactionImport")
  end

  def down
    # Cannot reverse: original TransactionPriorImport records cannot be distinguished from TransactionImport
  end
end
