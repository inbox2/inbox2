class Tag < ApplicationRecord
  key_prefix "tag"

  TAG_URGENT = "Urgent".freeze
  TAG_IMPORTANT = "Important".freeze
  # Eisenhower "Later" quadrant is urgent=false + important=false, which is
  # indistinguishable from an untriaged conversation by priority alone. This
  # marker tag records that a conversation was explicitly dropped into Later so
  # the placement survives a refresh.
  TAG_LATER = "Later".freeze

  COLOR_URGENT = "#e06060".freeze
  COLOR_IMPORTANT = "#d4a843".freeze
  COLOR_LATER = "#6b7280".freeze

  SYSTEM_TAGS = [
    { name: TAG_URGENT, color: COLOR_URGENT },
    { name: TAG_IMPORTANT, color: COLOR_IMPORTANT },
    { name: TAG_LATER, color: COLOR_LATER }
  ].freeze

  belongs_to :organization
  # A private label (docs/plans/mail-import.md D11): its member alone sees it,
  # on any conversation they can see. Without one, the team's tag.
  belongs_to :membership, optional: true

  validates :name, presence: true, uniqueness: { scope: %i[organization_id membership_id] }
  validates :color, presence: true
  # Clients find the priority tags by name; a private "Urgent" would be mistaken for it.
  validate :private_name_not_reserved, if: :private?

  scope :system_tags, -> { where(system: true) }
  scope :user_tags, -> { where(system: false) }
  scope :org_wide, -> { where(membership_id: nil) }
  # The team's tags plus the member's own; org-wide only without a member.
  scope :visible_to, ->(membership) { where(membership_id: [nil, membership&.id].uniq) }

  def private? = membership_id.present?

  def visible_to?(membership) = membership_id.nil? || membership_id == membership&.id

  RESERVED_NAMES = SYSTEM_TAGS.map { |t| t[:name].downcase }.freeze

  def self.ensure_system_tags(organization)
    # One read on the hot path (tags#index, every org create); writes only for
    # a tag that is actually missing.
    present = org_wide.where(organization: organization, name: SYSTEM_TAGS.map { |t| t[:name] }).pluck(:name)
    SYSTEM_TAGS.each do |attrs|
      next if present.include?(attrs[:name])

      find_or_create_by!(organization: organization, membership_id: nil, name: attrs[:name]) do |t|
        t.color = attrs[:color]
        t.system = true
      end
    end
  end

  private

  # Clients filter by name, so a private "Clients" beside the team's "Clients"
  # could not be told apart; the team's name wins.
  def private_name_not_reserved
    if RESERVED_NAMES.include?(name.to_s.downcase)
      errors.add(:name, "is kept for priority (#{name})")
    elsif Tag.org_wide.where(organization_id: organization_id).exists?(["LOWER(name) = ?", name.to_s.downcase])
      errors.add(:name, "is already a team tag (#{name})")
    end
  end
end
