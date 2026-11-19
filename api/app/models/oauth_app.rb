# A third-party application registered by an org admin in the console, allowed to
# broker provider OAuth (Google / Microsoft 365) through inbox2 — see
# docs/App-OAuth.md. The app's server starts a flow with an inbox2 API key; the
# user sees a branded consent screen (this name + icon, "powered by inbox2") and
# is returned to one of the whitelisted `redirect_uris`.
class OauthApp < ApplicationRecord
  key_prefix "oap"

  # A callback must be https, or plain-http loopback for local development. An
  # exact-match whitelist is the only thing standing between a stolen API key and
  # a token being delivered to an attacker's server, so it's validated on write
  # as well as matched on use.
  LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze
  MAX_REDIRECT_URIS = 10

  belongs_to :organization
  belongs_to :created_by, class_name: "User", optional: true
  has_many :oauth_grants, dependent: :destroy

  validates :name, presence: true, length: { maximum: 100 },
                   uniqueness: { scope: :organization_id, case_sensitive: false }
  validate :redirect_uris_are_valid

  # Resolve by public id (oap_…) or by name, so a calling app can identify itself
  # with whichever it has configured. Scoped to the caller's orgs by `scope`.
  def self.resolve(scope, identifier)
    identifier = identifier.to_s
    return nil if identifier.blank?

    scope.find_by(key: identifier) || scope.where("lower(name) = ?", identifier.downcase).first
  end

  # Exact string match — no prefix/suffix matching, which is how open redirects
  # get in (`https://app.test.evil.com` prefixed by `https://app.test`).
  def allows_redirect?(uri) = redirect_uris.include?(uri.to_s)

  def self.valid_redirect_uri?(value)
    uri = URI.parse(value.to_s)
    return false if uri.fragment.present?
    return true if uri.scheme == "https" && uri.host.present?

    uri.scheme == "http" && LOOPBACK_HOSTS.include?(uri.host)
  rescue URI::InvalidURIError
    false
  end

  private

  def redirect_uris_are_valid
    uris = Array(redirect_uris).map { |u| u.to_s.strip }.reject(&:blank?)
    self.redirect_uris = uris.uniq

    errors.add(:redirect_uris, "must include at least one callback URL") if redirect_uris.empty?
    errors.add(:redirect_uris, "is limited to #{MAX_REDIRECT_URIS} URLs") if redirect_uris.size > MAX_REDIRECT_URIS
    redirect_uris.each do |uri|
      next if self.class.valid_redirect_uri?(uri)

      errors.add(:redirect_uris, "#{uri} must be an https URL (or http on localhost) without a fragment")
    end
  end
end
