# A shareable scheduling link (docs/Calendar.md): shows the invitee's busy/free
# to anyone holding the URL and takes meeting *requests* — nothing is booked
# until the invitee accepts.
#
# Creator and invitee are separate on purpose: any member can make a link that
# books a colleague. The creator manages the link; the invitee owns the
# decision (the request lands in their inbox).
class MeetLink < ApplicationRecord
  key_prefix "mtl"

  CONFERENCE_MODES = %w[none meet teams].freeze
  CONFERENCE_NONE = "none".freeze
  CONFERENCE_MEET = "meet".freeze
  CONFERENCE_TEAMS = "teams".freeze

  DURATIONS = [15, 30, 45, 60, 90, 120].freeze
  MAX_AHEAD_DAYS_CEILING = 365

  belongs_to :organization
  belongs_to :membership
  belongs_to :invitee_membership, class_name: "Membership"
  has_many :meeting_requests, dependent: :destroy

  before_validation :default_invitee
  before_validation :generate_token, on: :create

  validates :label, presence: true
  validates :token, presence: true, uniqueness: true
  validates :duration_minutes, inclusion: { in: DURATIONS }
  validates :conference_mode, inclusion: { in: CONFERENCE_MODES }
  validates :min_notice_minutes, numericality: { greater_than_or_equal_to: 0 }
  validates :max_ahead_days, numericality: { greater_than: 0, less_than_or_equal_to: MAX_AHEAD_DAYS_CEILING }
  validate :invitee_in_same_organization
  # Only meaningful for a mode being set: revoking a link must not fail because
  # the invitee disconnected their provider after creation.
  validate :conference_mode_supported, if: :conference_mode_changed?

  scope :active, -> { where(revoked_at: nil) }

  def active? = revoked_at.nil?

  def revoke!
    update!(revoked_at: Time.current)
  end

  # The bookable window, evaluated at request time.
  def window
    from = Time.current + min_notice_minutes.minutes
    to = Time.current + max_ahead_days.days
    from..to
  end

  private

  def default_invitee
    self.invitee_membership_id ||= membership_id
  end

  # The URL capability. Distinct from `key` so a public id leaking in logs or
  # serializer output never doubles as a booking capability.
  def generate_token
    self.token ||= Nanoid.generate(size: 24)
  end

  def invitee_in_same_organization
    return if invitee_membership.nil? || invitee_membership.organization_id == organization_id

    errors.add(:invitee_membership, "must belong to the same organization")
  end

  # A Meet/Teams mode is a promise the ACCEPT can keep — and accept generates
  # the link with the invitee's connection, not the creator's.
  def conference_mode_supported
    return if conference_mode == CONFERENCE_NONE || invitee_membership.nil?

    provider = conference_mode == CONFERENCE_MEET ? OauthProvider::GOOGLE : OauthProvider::MICROSOFT
    return if ConferencingConnection.exists?(membership: invitee_membership, provider: provider)

    whose = invitee_membership_id == membership_id ? "your" : "#{invitee_membership.user&.then { |u| u.display_name.presence || u.username } || 'the invitee'}'s"
    errors.add(:conference_mode, "needs #{whose} #{OauthProvider.label(provider)} connection first")
  end
end
