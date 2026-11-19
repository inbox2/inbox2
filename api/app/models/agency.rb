class Agency < ApplicationRecord
  key_prefix "agy"

  STATUSES = %w[active suspended].freeze
  STATUS_ACTIVE = "active".freeze
  STATUS_SUSPENDED = "suspended".freeze

  belongs_to :owner, class_name: "User"
  has_many :organizations, dependent: :nullify

  validates :name, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :discount_percent, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }

  def total_organizations
    organizations.count
  end

  def consolidated_monthly_cost_cents
    base = organizations.count * 1900 # $19/org/month
    discount = (base * discount_percent / 100.0).round
    base - discount
  end
end
