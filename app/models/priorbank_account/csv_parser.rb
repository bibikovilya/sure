class PriorbankAccount::CsvParser
  FILE_LINES = {
    transaction_start: "Операции по ",
    headers: "Дата транзакции,Операция,Сумма,Валюта",
    transaction_end: "Всего по контракту"
  }.freeze

  NUMBER_FORMAT = "1.234,56".freeze
  DATE_FORMAT = "%d.%m.%Y %H:%M:%S".freeze

  attr_reader :account

  def initialize(account)
    @account = account
  end

  def parse(csv_data)
    transaction_lines = self.class.extract_transaction_lines(csv_data)
    parse_transaction_lines(transaction_lines)
  end

  # Class method to allow reuse in TransactionPriorImport
  def self.extract_transaction_lines(raw_csv)
    lines = raw_csv.split("\n")
    csv_lines = []
    in_transaction_section = false
    header_found = false

    lines.each do |line|
      if line.start_with?(FILE_LINES[:transaction_start])
        in_transaction_section = true
      elsif line.start_with?(FILE_LINES[:headers])
        csv_lines << line unless header_found
        header_found = true
      elsif in_transaction_section && line.match(/^#{FILE_LINES[:transaction_end]}/)
        in_transaction_section = false
      elsif in_transaction_section && line.strip.present? && line.include?(",")
        csv_lines << line
      end
    end

    csv_lines
  end

  private

    def parse_transaction_lines(lines)
      return [] if lines.empty?

      csv_data = lines.join("\n")
      # Reuse Import's CSV parsing logic
      parsed_csv = Import.parse_csv_str(csv_data, col_sep: ",")

      parsed_csv.map do |row|
        {
          date: parse_date(row["Дата транзакции"]),
          amount: sanitize_number(row["Обороты по счету"]),
          name: row["Операция"].to_s,
          currency: account.currency,
          notes: row.to_h.values.join(",") # Store full line in notes for deduplication
        }
      end
    end

    def sanitize_number(value)
      return BigDecimal(0) if value.nil? || value.to_s.strip.empty?

      # Reuse Import's sanitize_number logic by creating a temporary import instance
      # Import#sanitize_number returns a string, so we convert to BigDecimal
      temp_import = Import.new(number_format: NUMBER_FORMAT)
      sanitized_string = temp_import.send(:sanitize_number, value)

      return BigDecimal(0) if sanitized_string.blank?

      BigDecimal(sanitized_string)
    rescue ArgumentError
      BigDecimal(0)
    end

    def parse_date(value)
      return Date.current if value.nil? || value.to_s.strip.empty?

      # Handle Priorbank format: "29.03.2024 19:32:46"
      Date.strptime(value.to_s, DATE_FORMAT)
    rescue
      Date.current
    end
end
