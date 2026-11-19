# One recorded open of a tracked outbound message — a pixel hit. Keyed on the
# opaque `token` (not a Message FK): MX opens carry organization_id and correlate
# to a Message via messages.tracking_token; local-channel opens carry only the
# token (the server never holds the client's message) and the client polls by it.
class MessageOpen < ApplicationRecord
  key_prefix "mo"

  belongs_to :organization, optional: true

  validates :token, presence: true

  # Records a pixel hit from the pixel controller. Resolves the real client IP
  # across proxy forwards (Cloudflare, then X-Forwarded-For's leftmost hop), flags
  # provider-proxy/prefetch hits, and schedules a lazy geo lookup.
  def self.record!(token:, request:, organization_id: nil)
    ua = request.user_agent
    proxied, kind = Tracking.classify_proxy(ua)

    open = create!(
      token: token,
      organization_id: organization_id,
      ip: Tracking.client_ip(request),
      user_agent: ua,
      proxied: proxied,
      proxy_kind: kind,
      opened_at: Time.current
    )
    ResolveGeoJob.perform_later("MessageOpen", open.id) if open.ip.present?
    open
  end

  # A human render (excluded provider proxy/prefetch hits) — the count that
  # actually means "someone opened this".
  scope :real, -> { where(proxied: false) }
end
