class EspDomainSerializer < ApplicationSerializer
  attributes :name, :status, :dns_checks, :dns_checked_at, :created_at

  attribute :records do |domain|
    domain.required_records
  end
end
