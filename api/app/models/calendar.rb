class Calendar < ApplicationRecord
  key_prefix "cal"

  SOURCES = %w[inbox2].freeze
  SOURCE_INBOX2 = "inbox2".freeze

  STATUSES = %w[active error].freeze
  STATUS_ACTIVE = "active".freeze
  STATUS_ERROR = "error".freeze

  DEFAULT_NAME = "Calendar".freeze
  DEFAULT_COLOR = "#3B82F6".freeze

  belongs_to :organization
  belongs_to :membership, optional: true
  has_many :calendar_events, dependent: :destroy

  validates :name, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: STATUS_ACTIVE) }
  scope :visible, -> { where(is_visible: true) }
  # Org-wide calendars (no membership) span every domain, so a member scoped to
  # some domains (or only their own mailbox) doesn't get them.
  scope :for_member, ->(membership) {
    where(membership: membership.org_wide_access? ? [membership, nil] : membership)
  }

  # The member's own default calendar, created on first use. Nothing else
  # provisions one, so without this a brand-new member has zero calendars: the
  # calendar screen renders empty and event creation 404s on `calendar_id`.
  # Accepting an emailed invite and importing an .ics both land here too.
  #
  # ponytail: no unique index backs `is_primary`, so a simultaneous first-touch
  # from two requests can create two. `order(:created_at).first` keeps the
  # choice stable and the loser is an inert extra calendar — add a partial
  # unique index on (membership_id) WHERE is_primary if it ever shows up.
  def self.primary_for(organization, membership)
    scope = organization.calendars.where(membership: membership, is_primary: true)
    scope.order(:created_at).first || organization.calendars.create!(
      membership: membership,
      name: DEFAULT_NAME,
      color: DEFAULT_COLOR,
      is_primary: true,
      is_visible: true,
      source: SOURCE_INBOX2,
      status: STATUS_ACTIVE
    )
  end
end
