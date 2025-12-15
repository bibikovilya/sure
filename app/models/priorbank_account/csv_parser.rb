class PriorbankAccount::CsvParser
  FILE_LINES = {
    transaction_start: "Операции по ",
    headers: "Дата транзакции,Операция,Сумма,Валюта",
    transaction_end: "Всего по контракту",
    blocked_section: "Заблокированные суммы по",
    blocked_headers: "Дата транзакции,Транзакция,Сумма транзакции,Валюта"
  }.freeze

  NUMBER_FORMAT = "1.234,56".freeze
  DATE_FORMAT = "%d.%m.%Y %H:%M:%S".freeze

  attr_reader :account

  def initialize(account)
    @account = account
  end

  def parse(csv_data)
    result = {
      transactions: [],
      blocked_transactions: [],
      account_details: {}
    }

    result[:account_details] = extract_account_details(csv_data)
    transaction_lines = self.class.extract_transaction_lines(csv_data)
    result[:transactions] = parse_transaction_lines(transaction_lines)

    blocked_lines = extract_blocked_transaction_lines(csv_data)
    result[:blocked_transactions] = parse_blocked_transaction_lines(blocked_lines)

    result
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

    def extract_account_details(csv_data)
      lines = csv_data.split("\n")
      details = {}

      lines.each do |line|
        if line.start_with?("Доступная сумма:")
          details[:available_amount] = extract_amount_from_line(line)
        elsif line.start_with?("Заблокировано:")
          details[:blocked_amount] = extract_amount_from_line(line)
        elsif line.start_with?("Кредитный лимит:")
          details[:credit_limit] = extract_amount_from_line(line)
        end
      end

      details
    end

    def extract_amount_from_line(line)
      # Extract value after the colon and comma separator
      # Format: "Доступная сумма:,"168,75","
      parts = line.split(":", 2)
      return BigDecimal(0) if parts.length < 2

      value = parts[1].strip.gsub('"', "").sub(/^,/, "").sub(/,$/, "").strip

      sanitize_number(value)
    end

    def extract_blocked_transaction_lines(raw_csv)
      lines = raw_csv.split("\n")
      csv_lines = []
      in_blocked_section = false
      header_found = false

      lines.each do |line|
        if line.start_with?(FILE_LINES[:blocked_section])
          in_blocked_section = true
        elsif in_blocked_section && line.start_with?(FILE_LINES[:blocked_headers])
          csv_lines << line unless header_found
          header_found = true
        elsif in_blocked_section && line.strip.present? && line.include?(",") && !line.start_with?(FILE_LINES[:blocked_section])
          csv_lines << line
        end
      end

      csv_lines
    end

    def parse_blocked_transaction_lines(lines)
      return [] if lines.empty?

      csv_data = lines.join("\n")
      parsed_csv = Import.parse_csv_str(csv_data, col_sep: ",")

      parsed_csv.map do |row|
        {
          date: parse_date(row["Дата транзакции"]),
          amount: sanitize_number(row["Сумма блокировки"]),
          name: row["Транзакция"].to_s,
          currency: row["Валюта"].to_s.presence || account.currency,
          blocked: true,
          notes: row.to_h.values.join(",")
        }
      end
    end

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
