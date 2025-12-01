module Family::PriorbankConnectable
  extend ActiveSupport::Concern

  included do
    has_many :priorbank_items, dependent: :destroy
  end
end
