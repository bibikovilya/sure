module Family::PriorbankConnectable
  extend ActiveSupport::Concern

  included do
    has_many :priorbank_items, dependent: :destroy
    has_many :priorbank_accounts, through: :priorbank_items
  end
end
