class PriorbankAccount < ApplicationRecord
  include Syncable

  has_one :account, dependent: :nullify
  belongs_to :priorbank_item
  delegate :family, :login, :password, to: :priorbank_item

  validates :name, presence: true, uniqueness: true
  validates :currency, presence: true
end
