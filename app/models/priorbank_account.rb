class PriorbankAccount < ApplicationRecord
  include Syncable

  belongs_to :priorbank_item
  delegate :family, :login, :password, to: :priorbank_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider

  validates :name, presence: true, uniqueness: true
  validates :currency, presence: true
end
