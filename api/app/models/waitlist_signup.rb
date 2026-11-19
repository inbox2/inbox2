# A prospect who filled in the pre-launch interest form. Captured server-side,
# deduped on email (case-insensitive) without leaking existence to the public
# endpoint. An operator later flips one to "invited" from the SaaS surface, which
# mints a single-use invite_token; redeeming it at signup flips it to
# "registered" and links the created User. See docs/SaaS.md + the waitlist plan.
class WaitlistSignup < ApplicationRecord
  key_prefix "wls"

  # Lifecycle — referenced everywhere, never hardcoded as raw strings.
  STATUS_PENDING = "pending".freeze
  STATUS_INVITED = "invited".freeze
  STATUS_REGISTERED = "registered".freeze
  STATUSES = [STATUS_PENDING, STATUS_INVITED, STATUS_REGISTERED].freeze

  # "What do you do?" options on the web form (WaitlistPage INDUSTRIES) → label.
  INDUSTRY_LABELS = {
    "developer" => "Developer / Engineering",
    "designer" => "Designer",
    "founder" => "Founder / Owner",
    "product" => "Product",
    "marketing" => "Marketing",
    "sales" => "Sales",
    "support" => "Customer support",
    "operations" => "Operations",
    "agency" => "Agency / Consultancy",
    "other" => "Other"
  }.freeze

  belongs_to :user, optional: true

  normalizes :email, with: ->(e) { e.to_s.strip.downcase }

  validates :name, presence: true
  validates :email, presence: true,
    format: { with: URI::MailTo::EMAIL_REGEXP },
    uniqueness: { case_sensitive: false }
  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: STATUS_PENDING) }
  scope :invited, -> { where(status: STATUS_INVITED) }

  # Mint (or re-mint) a single-use invite token and move to "invited". Idempotent
  # enough to support re-inviting (re-sends a fresh link).
  def generate_invite_token!(invited_by: nil)
    update!(
      invite_token: SecureRandom.urlsafe_base64(32),
      invited_at: Time.current,
      invited_by: invited_by,
      status: STATUS_INVITED
    )
    invite_token
  end

  # An invite is redeemable only while it is the active outstanding invite and
  # the prospect has not already registered.
  def invite_redeemable?
    status == STATUS_INVITED && invite_token.present?
  end

  def industry_label
    INDUSTRY_LABELS.fetch(industry, industry.presence)
  end

  def mark_registered!(user)
    update!(
      user: user,
      status: STATUS_REGISTERED,
      registered_at: Time.current,
      invite_token: nil
    )
  end

  def self.find_redeemable_by_token(token)
    return nil if token.blank?

    invited.find_by(invite_token: token)
  end

  # Whether direct signups are gated behind an invite. Flipped off (open signups)
  # for the public prod rollout. See the INVITE_ENABLED env var.
  def self.invite_only?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("INVITE_ENABLED", "false"))
  end
end
