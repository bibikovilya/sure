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
      account = priorbank_account.account
      next unless account

      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
    end
  end

  def linked_priorbank_accounts
    priorbank_accounts.joins(:account_provider)
  end

  def unlinked_priorbank_accounts
    priorbank_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
  end
end
