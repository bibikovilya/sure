class Provider::PriorbankAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("PriorbankAccount", self)

  def provider_name
    "priorbank"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_priorbank_item_path(item)
  end

  def item
    provider_account.priorbank_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    "prior.by"
  end

  def institution_name
    "Priorbank"
  end

  def institution_url
    "https://www.prior.by/"
  end

  def institution_color
    "#FFE000"
  end
end
