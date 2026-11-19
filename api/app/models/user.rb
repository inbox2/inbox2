class User < ApplicationRecord
  key_prefix "usr"

  has_secure_password

  # TOTP seed is a credential equivalent to a password — never store it in the
  # clear. Encrypted at rest via Active Record encryption (see encryption.rb).
  encrypts :totp_secret

  has_many :sessions, dependent: :destroy
  has_many :memberships, dependent: :destroy
  has_many :organizations, through: :memberships
  has_many :owned_organizations, class_name: "Organization", foreign_key: :owner_id, dependent: :nullify
  has_one :personal_workspace, class_name: "Organization", foreign_key: :personal_user_id, dependent: :destroy
  has_many :notifications, dependent: :destroy
  has_many :api_keys, dependent: :destroy
  has_many :zone_categories, -> { order(:position, :id) }, dependent: :destroy
  has_many :zones, dependent: :destroy
  has_many :zone_dismissals, dependent: :delete_all
  has_many :channel_tracking_settings, dependent: :destroy
  has_many :device_link_requests, dependent: :destroy
  has_many :push_subscriptions, dependent: :destroy
  has_many :push_devices, dependent: :destroy
  has_many :channel_push_subscriptions, dependent: :destroy
  has_many :stored_credentials, dependent: :destroy
  has_one :credential_vault, dependent: :destroy
  has_one :user_key, dependent: :destroy
  has_many :meta_channel_subscriptions, dependent: :destroy
  has_many :meta_webhook_events, dependent: :destroy
  has_many :webauthn_credentials, dependent: :destroy
  has_many :oauth_identities, dependent: :destroy
  has_many :saml_identities, dependent: :destroy

  # The external recovery/invite address: one account per address, compared
  # case-insensitively (index_users_on_lower_billing_email). `normalizes` also
  # lower-cases the value in `find_by`/`where`, so lookups hit the index.
  normalizes :billing_email, with: ->(e) { e.to_s.strip.downcase.presence }
  validates :billing_email, uniqueness: { case_sensitive: false }, allow_nil: true
  normalizes :pending_billing_email, with: ->(e) { e.to_s.strip.downcase.presence }

  # A new address waits in pending_billing_email until its owner clicks the mailed
  # link, so billing_email (where resets and notices go) only ever holds a confirmed one.
  BILLING_EMAIL_TOKEN_TTL = 24.hours

  def self.digest_billing_email_token(raw) = Digest::SHA256.hexdigest(raw.to_s)

  def self.find_by_billing_email_token(raw)
    return if raw.blank?

    where(billing_email_token_sent_at: BILLING_EMAIL_TOKEN_TTL.ago..)
      .find_by(billing_email_token_digest: digest_billing_email_token(raw))
  end

  # Returns the raw token for the mail; only its digest is stored.
  def begin_billing_email_change!(address)
    raw = SecureRandom.urlsafe_base64(32)
    update!(pending_billing_email: address, billing_email_token_digest: self.class.digest_billing_email_token(raw),
            billing_email_token_sent_at: Time.current)
    raw
  end

  def confirm_billing_email!
    update!(billing_email: pending_billing_email, pending_billing_email: nil,
            billing_email_token_digest: nil, billing_email_token_sent_at: nil)
  end

  validates :username, presence: true, uniqueness: true,
    format: { with: /\A[a-zA-Z0-9_\-]+\z/, message: "only allows letters, numbers, underscores, and hyphens" },
    length: { minimum: 3, maximum: 50 }
  # A username is also a From address on every org domain (Membership#can_send_as?),
  # so role addresses a team shares can't be claimed as someone's username.
  RESERVED_USERNAMES = %w[
    info sales support contact admin administrator billing help hello team office
    postmaster abuse hostmaster webmaster security noreply no-reply mailer-daemon root
  ].freeze
  validate(if: -> { new_record? || will_save_change_to_username? }) do
    errors.add(:username, "is reserved") if RESERVED_USERNAMES.include?(username.to_s.downcase)
  end

  # has_secure_password enforces presence on create but no minimum length.
  # Require a reasonable minimum whenever a password is being set (signup,
  # reset, change-password). allow_nil skips it on updates that leave it alone.
  validates :password, length: { minimum: 8 }, allow_nil: true

  # The languages the clients offer (ui/web/src/lib/languages.js); add one in both places.
  LANGUAGES = %w[en].freeze
  validates :default_language, inclusion: { in: LANGUAGES }, if: :will_save_change_to_default_language?

  # ── Scheduling preferences (docs/Calendar.md) ─────────────────────────────
  # The working day the scheduling assistant shades and ranks against, and an
  # out-of-office period that makes someone busy without them having to block
  # their own calendar.
  #
  # Stored on the user rather than the membership: these travel with the person,
  # and `default_timezone` — the attribute they are meaningless without — already
  # lives here. A member of two orgs keeps one working day across both.
  # ponytail: one OOO period, not a table. "I'm away next week" is the whole
  # ask; a second overlapping absence would need `out_of_office_periods`.

  # Minutes from local midnight, so half-hours work and comparison is integer
  # arithmetic. 09:00–17:00, Monday–Friday.
  DEFAULT_WORKING_HOURS = {
    "start_minute" => 9 * 60,
    "end_minute" => 17 * 60,
    "days" => [1, 2, 3, 4, 5]
  }.freeze

  MINUTES_IN_DAY = 24 * 60

  # Form params arrive as strings ("540"), and jsonb stores exactly what it is
  # given — so without this the column ends up holding strings and anything
  # reading it raw compares a String to an Integer. Normalized on the model so
  # every writer is covered, not just the account endpoint.
  before_validation :normalize_working_hours
  validate :working_hours_shape

  # Touch Strip (docs/Touch-Strip.md): the widget ids a strip can hold, and the
  # sections of the synced `touch_strip` layout. Its nested shape is allow-listed
  # at the controller; the model caps the size and pins `items` to known widgets.
  TOUCH_STRIP_ITEMS = %w[clocks weather stocks crypto news ip].freeze
  TOUCH_STRIP_KEYS = %i[items clocks places stocks crypto feeds options].freeze
  TOUCH_STRIP_MAX_BYTES = 16 * 1024
  validate :touch_strip_shape

  # Lore "Handled for you" auto mode (docs/Triage.md "Auto mode"): the buckets
  # this person lets file new mail away by themselves. Off unless set.
  LORE_AUTO_LABELS = [TriageLabel::FYI, TriageLabel::RECEIPT, TriageLabel::NOTIFICATION].freeze

  def lore_auto_settings
    LORE_AUTO_LABELS.to_h { |label| [label, lore_auto&.dig(label) == true] }
  end

  def lore_auto_on?(label) = lore_auto_settings[label] == true

  # NULL means "never set" and falls back to the default — an empty working day
  # would make every suggestion read as out-of-hours.
  def effective_working_hours
    stored = working_hours.presence || {}
    {
      "start_minute" => integer_or_default(stored["start_minute"], "start_minute"),
      "end_minute" => integer_or_default(stored["end_minute"], "end_minute"),
      "days" => valid_days(stored["days"]) || DEFAULT_WORKING_HOURS["days"]
    }
  end

  def out_of_office?(at = Time.current)
    return false if out_of_office_start.blank? || out_of_office_end.blank?

    at >= out_of_office_start && at < out_of_office_end
  end

  # The slice of an out-of-office period that lands inside [from, to), or nil.
  # Used to draw OOO as a busy block on the availability grid.
  def out_of_office_overlap(from, to)
    return nil if out_of_office_start.blank? || out_of_office_end.blank?
    return nil unless out_of_office_start < to && out_of_office_end > from

    [[out_of_office_start, from].max, [out_of_office_end, to].min]
  end

  def accessible_organizations
    Organization.teams.joins(:memberships).where(memberships: { user_id: id, status: Membership::STATUS_ACTIVE })
  end

  # The hidden workspace that holds this person's C:\ (Organization.personal_for),
  # and their membership of it, which is the custodian of every C:\ node.
  def personal_organization = @personal_organization ||= Organization.personal_for(self)
  def personal_membership = @personal_membership ||= personal_organization.memberships.find_by!(user_id: id)

  def generate_reset_token!
    update!(
      reset_token: SecureRandom.hex(32),
      reset_token_expires_at: 1.hour.from_now
    )
    reset_token
  end

  def reset_token_valid?
    reset_token.present? && reset_token_expires_at&.future?
  end

  def clear_reset_token!
    update!(reset_token: nil, reset_token_expires_at: nil)
  end

  def totp_enabled?
    totp_enabled == true && totp_secret.present?
  end

  # Single gating chokepoint for push (cloud push on local channels + mobile
  # push). Paid feature (TODO 45.6): enabled when any of the user's active orgs
  # is on a paid plan. PUSH_FREE_FOR_ALL=1 restores the ungated behavior (dev /
  # launch promos).
  def push_enabled?
    return true if ENV["PUSH_FREE_FOR_ALL"].present?

    accessible_organizations.any? { |org| !org.on_free_plan? }
  end

  # Whether it is safe to demand a passkey at sign-in with `count` passkeys on the
  # account: there is one to present, and a second way in (another passkey, or a
  # TOTP code) for the day that device is lost. Guards turning the requirement on
  # and removing a passkey while it is on.
  def passkey_fallback?(count = webauthn_credentials.count)
    count >= 1 && (count >= 2 || totp_enabled?)
  end

  def verify_totp(code)
    return false unless totp_enabled? && code.present?

    totp = ROTP::TOTP.new(totp_secret, issuer: "Inbox2")
    # drift_behind: 1 keeps the acceptance window to the current ±30s step (the
    # old value of 15 accepted ~7.5 min of codes — a 15× brute-force boost).
    # after: rejects replay of a code from a timestep we've already consumed.
    verified_at = totp.verify(code, drift_behind: 1, drift_ahead: 1, after: totp_last_verified_at)
    return false unless verified_at

    update_column(:totp_last_verified_at, Time.at(verified_at).utc)
    true
  end

  private

  def normalize_working_hours
    return if working_hours.blank? || !working_hours.is_a?(Hash)

    normalized = working_hours.transform_keys(&:to_s)
    %w[start_minute end_minute].each do |field|
      normalized[field] = normalized[field].to_i if normalized[field].present?
    end
    if normalized["days"].present?
      normalized["days"] = Array(normalized["days"]).map(&:to_i).uniq.sort
    end
    self.working_hours = normalized
  end

  def integer_or_default(value, field)
    return DEFAULT_WORKING_HOURS[field] unless value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)

    value.to_i
  end

  def valid_days(days)
    return nil unless days.is_a?(Array)

    cleaned = days.map(&:to_i).select { |d| d.between?(0, 6) }.uniq.sort
    cleaned.presence
  end

  # Rejects a shape the scheduler could not act on. A blank column is fine —
  # that is the "use the default" state, not an invalid one.
  def touch_strip_shape
    return errors.add(:touch_strip, "must be an object") unless touch_strip.is_a?(Hash)
    return errors.add(:touch_strip, "is too large") if touch_strip.to_json.bytesize > TOUCH_STRIP_MAX_BYTES

    unknown = Array(touch_strip["items"]) - TOUCH_STRIP_ITEMS
    errors.add(:touch_strip, "has unknown items: #{unknown.join(', ')}") if unknown.any?
  end

  def working_hours_shape
    return if working_hours.blank?

    unless working_hours.is_a?(Hash)
      errors.add(:working_hours, "must be an object")
      return
    end

    start_minute = working_hours["start_minute"]
    end_minute = working_hours["end_minute"]
    if start_minute.present? || end_minute.present?
      from = start_minute.to_i
      to = end_minute.to_i
      errors.add(:working_hours, "start must be within the day") unless from.between?(0, MINUTES_IN_DAY)
      errors.add(:working_hours, "end must be within the day") unless to.between?(0, MINUTES_IN_DAY)
      errors.add(:working_hours, "end must be after start") if to <= from
    end

    days = working_hours["days"]
    if days.present? && (!days.is_a?(Array) || days.map(&:to_i).any? { |d| !d.between?(0, 6) })
      errors.add(:working_hours, "days must be weekday numbers 0-6")
    end
  end
end
