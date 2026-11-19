# One recorded click of a tracked link — a hit on GET /l/:token before the 302.
# Keyed on the TrackedLink's token (the redirect endpoint holds only the token),
# mirroring MessageOpen.
class LinkClick < ApplicationRecord
  key_prefix "lc"

  belongs_to :organization, optional: true

  validates :token, presence: true

  # Records a click from the redirect controller: real client IP across proxy
  # forwards, flags security-scanner/prefetch hits, schedules a lazy geo lookup.
  def self.record!(token:, request:, organization_id: nil)
    ua = request.user_agent
    bot, kind = Tracking.classify_click_bot(ua)

    click = create!(
      token: token,
      organization_id: organization_id,
      ip: Tracking.client_ip(request),
      user_agent: ua,
      proxied: bot,
      proxy_kind: kind,
      clicked_at: Time.current
    )
    ResolveGeoJob.perform_later("LinkClick", click.id) if click.ip.present?
    click
  end

  # A human click (excluded security-scanner/prefetch hits).
  scope :real, -> { where(proxied: false) }
end
