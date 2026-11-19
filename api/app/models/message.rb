class Message < ApplicationRecord
  key_prefix "msg"

  # "Undo send" window: outbound delivery is deferred this long so a cancel-send
  # within the window can intercept it (the delivery job skips drafts). Mirrors the
  # Gmail-style undo affordance the client shows right after a send.
  SEND_UNDO_WINDOW = 10.seconds

  # E2EE message sealing (docs/E2EE.md). `none` = plaintext columns; `sealed_box_v1`
  # = body/header stored as ciphertext (xchacha20poly1305, DEK sealed to the domain
  # key) with the plaintext columns (body_*, subject, from_address, …) left null.
  ENCRYPTION_SCHEME_NONE = "none".freeze
  ENCRYPTION_SCHEME_SEALED_BOX_V1 = "sealed_box_v1".freeze
  # v2 binds each part's role into the AAD ("<aad>|header", "<aad>|body"), so a
  # server can't swap the two parts. v1 mail stays readable. See docs/E2EE.md.
  ENCRYPTION_SCHEME_SEALED_BOX_V2 = "sealed_box_v2".freeze
  SEALED_ENCRYPTION_SCHEMES = [ENCRYPTION_SCHEME_SEALED_BOX_V1, ENCRYPTION_SCHEME_SEALED_BOX_V2].freeze
  ENCRYPTION_SCHEMES = [ENCRYPTION_SCHEME_NONE, *SEALED_ENCRYPTION_SCHEMES].freeze

  # Meeting-invite RSVP state on a message carrying a `text/calendar; METHOD:REQUEST`
  # part (docs/Meeting-Invites.md). Vocabulary is shared with CalendarAttendee so
  # the two RSVP surfaces never drift. `nil` rsvp_status = not an invite / unanswered.
  # RFC 3834 Auto-Submitted values. "auto-replied" marks an out-of-office reply
  # so the receiving side knows not to answer it (docs/Calendar.md).
  AUTO_SUBMITTED_REPLIED = "auto-replied".freeze
  AUTO_SUBMITTED_GENERATED = "auto-generated".freeze

  RSVP_STATUSES = CalendarAttendee::RESPONSE_STATUSES # needs_action/accepted/declined/tentative
  RSVP_RESPONSES = %w[accepted declined tentative].freeze # the actionable answers

  # RFC 5545 METHODs we store on `calendar_invite`. REQUEST is an invitation to
  # answer (RSVP banner); PUBLISH is an event to file (Add-to-calendar banner) and
  # also stands in for a bare VEVENT that names no METHOD at all.
  CALENDAR_METHOD_REQUEST = "REQUEST".freeze
  CALENDAR_METHOD_PUBLISH = "PUBLISH".freeze

  # counter_cache keeps conversations.messages_count current so the conversation
  # list serializer reads a column instead of a COUNT(*) per row. Every write path
  # goes through this association (.create!/.build), so the cache stays accurate.
  belongs_to :conversation, counter_cache: true
  belongs_to :organization
  # A private copy's member (imported history and replies into it,
  # docs/plans/mail-import.md D9): the Message-ID is unique per (org, owner).
  # Always the conversation's owner; shared mail has none.
  belongs_to :owner, class_name: "Membership", foreign_key: :owner_membership_id, optional: true
  # One row per delivery DESTINATION (recipient domain, or the ESP itself) —
  # see the AddDestinationsToDeliveryStatuses migration. `delivery_status` is
  # the convenience reader for the single-destination case.
  has_many :delivery_statuses, dependent: :destroy
  has_one :delivery_status, -> { order(:id) }, class_name: "DeliveryStatus", inverse_of: :message, dependent: nil
  # Meet-link request carried by this message (docs/Calendar.md). Nullify so
  # deleting the conversation/message never trips the FK — the request row is
  # the durable record.
  has_one :meeting_request_record, class_name: "MeetingRequest", dependent: :nullify
  has_many :attachments, dependent: :destroy
  # Open-tracking pixel hits (docs/Open-Tracking.md), correlated by the capability
  # token embedded in the sent mail rather than a FK (the pixel endpoint holds only
  # the token). Present only on tracked outbound messages.
  has_many :opens, -> { order(opened_at: :asc) }, class_name: "MessageOpen",
    primary_key: :tracking_token, foreign_key: :token, dependent: :destroy, inverse_of: false
  # Rewritten links of a tracked message, keyed the same way; preloadable so the
  # reading pane renders links + clicks without a query per message.
  has_many :tracked_links, -> { order(created_at: :asc) }, class_name: "TrackedLink",
    primary_key: :tracking_token, foreign_key: :message_tracking_token, inverse_of: false

  validates :encryption_scheme, inclusion: { in: ENCRYPTION_SCHEMES }
  # Sealed rows carry the sender inside the header ciphertext, never in plaintext.
  validates :from_address, presence: true, unless: :sealed?

  # A missing Message-ID must store as NULL, never "". The unique index on
  # (organization_id, message_id_header) is partial (WHERE ... IS NOT NULL), so an
  # empty string is treated as a real, unique value — the second header-less mail
  # per org then hits RecordNotUnique and strands a message-less conversation
  # (the orphaned, body-less threads seen for header-less spam).
  before_validation { self.message_id_header = message_id_header.presence }
  # A draft is its author's private copy: DraftsController sets the owner.
  before_validation(on: :create) { self.owner_membership_id ||= conversation&.owner_membership_id }

  # Mail in no one's private copy: what inbound dedupes and threads against.
  scope :shared, -> { where(owner_membership_id: nil) }

  # Another member's draft is theirs alone (2026-10-24); a reader that is no
  # member (API key) sees no drafts.
  scope :readable_by, ->(membership) {
    membership ? where(is_draft: false).or(where(owner_membership_id: membership.id)) : where(is_draft: false)
  }

  def readable_by?(membership) = !is_draft || (membership.present? && owner_membership_id == membership.id)

  # The words search matches (SearchController): headers + body + the text of
  # every attachment, as one document — Gmail's model, so "btw nummer sizio"
  # hits when "nummer" lives only in the attached PDF. 'simple', not 'english':
  # most of this mail is Dutch, and English stemming mangles Dutch words.
  # Sealed mail is NULL (no plaintext here). Capped well under tsvector's 1MB.
  SEARCH_VECTOR_SQL = <<~SQL.squish.freeze
    CASE WHEN messages.encryption_scheme = '#{ENCRYPTION_SCHEME_NONE}' THEN
      to_tsvector('simple', left(concat_ws(' ',
        messages.subject, messages.from_address, messages.to_address, messages.cc_address,
        COALESCE(NULLIF(messages.body_plain, ''), regexp_replace(messages.body_html, '<[^>]*>', ' ', 'g')),
        (SELECT string_agg(a.content_text, ' ') FROM attachments a WHERE a.message_id = messages.id)
      ), 500000))
    END
  SQL
  SEARCH_SOURCE_COLUMNS = %w[subject from_address to_address cc_address body_plain body_html encryption_scheme].freeze

  # update_all on purpose: no callbacks re-entering, one statement per batch.
  def self.refresh_search_vectors(scope)
    where(id: scope).update_all("search_vector = #{SEARCH_VECTOR_SQL}")
  end

  after_save -> { Message.refresh_search_vectors(id) },
             if: -> { saved_changes.keys.intersect?(SEARCH_SOURCE_COLUMNS) }

  # Here, not in the send paths: compose, schedule, undo, MCP and calendar all land on this row.
  after_save -> { conversation.refresh_sent_only! }, if: -> { saved_change_to_id? || saved_change_to_is_draft? }

  def sealed?
    SEALED_ENCRYPTION_SCHEMES.include?(encryption_scheme)
  end

  # Outbound message carrying a tracking pixel (open tracking was on at send).
  def tracked?
    tracking_token.present?
  end
end
