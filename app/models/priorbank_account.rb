class PriorbankAccount < ApplicationRecord
  include Syncable

  belongs_to :priorbank_item
  delegate :family, :login, :password, to: :priorbank_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider

  validates :name, presence: true, uniqueness: true
  validates :currency, presence: true

  def sync_window
    start_date = calculate_sync_window_start
    end_date = Date.current

    { start_date: start_date, end_date: end_date }
  end

  private

    def calculate_sync_window_start
      # Try to get the last successful sync's window_end_date
      last_completed_sync = syncs.where(status: "completed").order(created_at: :desc).first
      return last_completed_sync.window_end_date if last_completed_sync&.window_end_date.present?

      # Fall back to latest entry date
      latest_entry_date = account&.entries.maximum(:date)
      return latest_entry_date if latest_entry_date.present?

      # Default to 3 months ago
      3.months.ago.to_date
    end
end
