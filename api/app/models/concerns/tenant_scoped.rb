module TenantScoped
  extend ActiveSupport::Concern

  included do
    belongs_to :organization

    scope :for_organization, ->(org) { where(organization: org) }

    validates :organization, presence: true
  end
end
