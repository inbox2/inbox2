class AgencySerializer < ::ApplicationSerializer
  attributes :name, :status, :discount_percent, :billing_email, :created_at

  attribute :total_organizations do |agency|
    agency.total_organizations
  end

  attribute :consolidated_monthly_cost_cents do |agency|
    agency.consolidated_monthly_cost_cents
  end
end
