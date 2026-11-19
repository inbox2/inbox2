# A visitor's ask for a slot on a meet link (docs/Calendar.md). Lives next to
# the inbox message that renders the Accept/Decline banner; `message.meeting_request`
# mirrors the fields the same way `calendar_invite` mirrors a parsed ICS.
class MeetingRequest < ApplicationRecord
  key_prefix "mrq"

  STATUSES = %w[pending accepted declined expired].freeze
  STATUS_PENDING = "pending".freeze
  STATUS_ACCEPTED = "accepted".freeze
  STATUS_DECLINED = "declined".freeze
  STATUS_EXPIRED = "expired".freeze

  belongs_to :organization
  belongs_to :meet_link
  belongs_to :message, optional: true
  belongs_to :calendar_event, optional: true

  validates :name, presence: true
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :start_at, presence: true
  validates :end_at, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: STATUS_PENDING) }

  def pending? = status == STATUS_PENDING

  # Lazy expiry: a pending request whose start has passed can no longer be
  # meaningfully answered. Called under the decision row lock; returns true
  # when this call did the expiring.
  def expire_if_stale!
    return false unless pending? && start_at < Time.current

    update!(status: STATUS_EXPIRED)
    sync_message!
    true
  end

  # The banner payload stored on the inbox message. Status rides along so the
  # client can collapse the banner to "You accepted" without a second fetch.
  def banner_payload
    {
      "key" => key,
      "name" => name,
      "email" => email,
      "note" => note,
      "start" => start_at.iso8601,
      "end" => end_at.iso8601,
      "visitor_timezone" => visitor_timezone,
      "link_label" => meet_link.label,
      "conference_mode" => meet_link.conference_mode,
      # Who this request books — the banner only offers Accept/Decline to them;
      # everyone else sharing the pool sees a read-only "waiting" row.
      "invitee_email" => meet_link.invitee_membership.primary_email_address,
      "invitee_name" => meet_link.invitee_membership.user&.display_name,
      "status" => status
    }
  end

  # Keep the message's copy of the payload in step with a status change.
  def sync_message!
    message&.update!(meeting_request: banner_payload)
  end
end
