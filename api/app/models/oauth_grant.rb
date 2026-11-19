# One in-flight provider authorization for a registered OauthApp
# (docs/App-OAuth.md). Created when the app's server starts a flow, carried
# through the consent page and the provider round-trip as the OAuth `state`, and
# consumed when the app redeems the tokens with its inbox2 API key.
#
# The grant's public key (oag_…, a 21-char nanoid) IS the flow handle: it travels
# in URLs the way an OAuth code does. It is not a bearer on its own — redemption
# additionally requires an API key belonging to the app's org — but it is
# single-use and short-lived regardless.
class OauthGrant < ApplicationRecord
  key_prefix "oag"

  STATUS_PENDING = "pending".freeze
  STATUS_AUTHORIZED = "authorized".freeze
  STATUS_CONSUMED = "consumed".freeze
  STATUSES = [STATUS_PENDING, STATUS_AUTHORIZED, STATUS_CONSUMED].freeze

  # Long enough for a real person to read the consent screen and log in to the
  # provider; short enough that an abandoned flow doesn't linger.
  FLOW_TTL = 15.minutes
  # The window the calling app has to redeem, once the provider has answered.
  REDEEM_TTL = 10.minutes

  belongs_to :oauth_app

  # Provider tokens live on the row for the few minutes between the provider
  # callback and redemption. Encrypted so a database read alone doesn't hand over
  # live mailbox access.
  encrypts :access_token
  encrypts :refresh_token

  validates :provider, inclusion: { in: OauthProvider::PROVIDERS }
  validates :status, inclusion: { in: STATUSES }
  validates :redirect_uri, presence: true

  before_validation :set_defaults, on: :create

  scope :stale, -> { where(expires_at: ...Time.current) }

  def expired? = expires_at.past?
  def pending? = status == STATUS_PENDING && !expired?
  def redeemable? = status == STATUS_AUTHORIZED && !expired?

  def provider_label = OauthProvider.label(provider)

  # Record the provider's answer and hand the redemption window to the app.
  def authorize!(tokens, email)
    update!(
      status: STATUS_AUTHORIZED,
      email: email,
      access_token: tokens["access_token"],
      refresh_token: tokens["refresh_token"],
      scope: tokens["scope"],
      token_expires_at: tokens["expires_in"].present? ? tokens["expires_in"].to_i.seconds.from_now : nil,
      expires_at: REDEEM_TTL.from_now
    )
  end

  # The one-time payload the calling app stores. Reading it consumes the grant —
  # the tokens are wiped from the row, so this row can never serve them twice.
  def redeem!
    payload = {
      provider: provider,
      email: email,
      access_token: access_token,
      refresh_token: refresh_token,
      expires_at: token_expires_at,
      scope: scope,
      state: client_state
    }
    update!(status: STATUS_CONSUMED, access_token: nil, refresh_token: nil)
    payload
  end

  # The app's whitelisted callback with the flow result appended (its own query
  # string, if it registered one, is preserved).
  def return_uri(extra = {})
    uri = URI.parse(redirect_uri)
    query = Rack::Utils.parse_query(uri.query).merge(extra.compact.stringify_keys)
    query["state"] = client_state if client_state.present?
    uri.query = query.to_query
    uri.to_s
  end

  private

  def set_defaults
    self.status ||= STATUS_PENDING
    self.expires_at ||= FLOW_TTL.from_now
  end
end
