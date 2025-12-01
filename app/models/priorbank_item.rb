class PriorbankItem < ApplicationRecord
  include Syncable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Check if ActiveRecord Encryption is configured
  def self.encryption_ready?
    creds_ready = Rails.application.credentials.active_record_encryption.present?
    env_ready = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].present?
    creds_ready || env_ready
  end

  # Encrypt sensitive credentials if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :login, deterministic: true
    encrypts :password, deterministic: true
  end

  validates :name, presence: true
  validates :login, presence: true, on: :create
  validates :password, presence: true, on: :create

  belongs_to :family
  has_many :priorbank_accounts, dependent: :destroy

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    priorbank_accounts.each do |priorbank_account|
      account = priorbank_account.current_account
      next unless account

      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
    end
  end

  def sync_status_summary
    latest = latest_sync
    return nil unless latest

    total_accounts = priorbank_accounts.count
    linked_count = family.accounts.where(priorbank_account_id: priorbank_accounts.select(:id)).count
    unlinked_count = total_accounts - linked_count

    if total_accounts == 0
      "No accounts configured"
    elsif unlinked_count == 0
      "#{linked_count} #{'account'.pluralize(linked_count)} synced"
    else
      "#{linked_count} synced, #{unlinked_count} need setup"
    end
  end
end
