class Space < ApplicationRecord
  key_prefix "spc"

  # Who can see a space's mail. `org` → visible to the whole domain;
  # `assigned` → only members staffed on the space (see space_memberships).
  OPENNESS = %w[org assigned].freeze
  OPENNESS_ORG = "org".freeze
  OPENNESS_ASSIGNED = "assigned".freeze

  # The holding pen: where mail triage couldn't place confidently lands.
  HOLDING_PEN_SLUG = "triage".freeze

  # Canonical spaces an org starts with — mirrors the web color system
  # (lib/spaceColors.js CANONICAL) so hues stay deterministic across clients.
  # `triage` is the holding pen: org-wide, never auto-classified into.
  DEFAULT_SPACES = [
    { slug: "support",   name: "Support",   icon: "globe",    openness: OPENNESS_ORG,      classify: true,
      description: "Customers asking for help: questions, complaints, bugs, account or product problems",
      not_for: "Automated notifications, newsletters and marketing" },
    { slug: "sales",     name: "Sales",     icon: "person.2", openness: OPENNESS_ASSIGNED, classify: true,
      description: "Buying interest: pricing, quotes, demos, deals, inbound leads and partnership offers",
      not_for: "Existing customers asking for help; cold pitches selling to us" },
    { slug: "marketing", name: "Marketing", icon: "globe",    openness: OPENNESS_ORG,      classify: true,
      description: "The team's own marketing work: campaigns, events, PR, social media and agencies",
      not_for: "Newsletters and promotions other companies send us" },
    { slug: "finance",   name: "Finance",   icon: "person.2", openness: OPENNESS_ASSIGNED, classify: true,
      description: "Money matters: invoices, bills, payments, receipts, taxes and VAT, budgets, financial reporting, accounting and expenses",
      not_for: "Marketing from banks or payment providers" },
    { slug: "operations", name: "Operations", icon: "globe", openness: OPENNESS_ORG,     classify: true,
      description: "Running the company: IT and cloud accounts, infrastructure, vendors and contracts, legal and company registration, HR and internal team work",
      not_for: "Anything about money: invoices, payments, taxes, VAT, budgets, accounting or financial reporting; and customer questions" },
    { slug: "triage",    name: "Triage",    icon: "globe",    openness: OPENNESS_ORG,      classify: false }
  ].freeze

  belongs_to :organization
  has_many :space_memberships, dependent: :destroy
  has_many :memberships, through: :space_memberships
  # Conversations keep their space on destroy (nullify) — mail is never deleted
  # just because a space is removed; it falls back to the holding pen.
  has_many :conversations, dependent: :nullify

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: { scope: :organization_id }
  validates :openness, inclusion: { in: OPENNESS }

  before_validation :generate_slug, on: :create

  scope :ordered, -> { order(position: :asc) }
  # Spaces the classifier may route into (everything except the holding pen).
  scope :classifiable, -> { where(classify: true) }

  # Transient, controller-populated stats so the serializer stays a pure
  # projection (avoids per-record queries inside Alba). { open:, unread:,
  # volume:, unassigned: } plus a list of { name:, avatar_url: } member summaries.
  attr_accessor :stats, :member_summaries

  # Seed an org's canonical spaces, idempotently (mirrors View.ensure_system_views).
  def self.ensure_default_spaces(organization)
    present = organization.spaces.where(slug: DEFAULT_SPACES.map { |d| d[:slug] }).pluck(:slug)
    DEFAULT_SPACES.each_with_index do |data, index|
      next if present.include?(data[:slug])

      organization.spaces.find_or_create_by!(slug: data[:slug]) do |s|
        s.name = data[:name]
        s.icon = data[:icon]
        s.openness = data[:openness]
        s.classify = data[:classify]
        s.description = data[:description]
        s.not_for = data[:not_for]
        s.position = index
      end
    end
  end

  private

  def generate_slug
    return if slug.present?
    base = name.to_s.parameterize
    base = "space" if base.blank?
    candidate = base
    n = 2
    while organization&.spaces&.exists?(slug: candidate)
      candidate = "#{base}-#{n}"
      n += 1
    end
    self.slug = candidate
  end
end
