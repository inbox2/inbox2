class DomainSerializer < ::ApplicationSerializer
  attributes :name, :status, :dns_checked_at, :created_at, :e2ee_enabled, :e2ee_notification_preview,
             :open_tracking_enabled, :link_tracking_enabled, :tracking_domain

  # Open tracking (docs/Open-Tracking.md): whether the custom tracking host's
  # CNAME + cert are verified (nil tracking_domain = using the inbox2 default).
  attribute :tracking_verified do |dom|
    dom.tracking_domain.blank? || dom.tracking_domain_verified_at.present?
  end

  # URL workspace slug (Domain#slug).
  attribute :slug, &:slug

  # Per-domain square icon (shown on the domain's workspace tab). Stored as an
  # internal storage key; expose the public brand endpoint that streams it (nil
  # when unset, so the client falls back to the org icon / name initials).
  attribute :icon_url do |dom|
    dom.icon_url.present? ? DomainSerializer.brand_url(dom) : nil
  end

  attribute :dns_checks do |dom|
    dom.dns_checks.presence
  end

  # Billing lock (over a downgraded plan's domain limit) — drives the "Locked"
  # badge + blocks inbound mail until upgrade.
  attribute :locked do |dom|
    dom.locked?
  end

  attribute :locked_at do |dom|
    dom.locked_at
  end

  def self.brand_url(dom)
    base = ENV.fetch("API_PUBLIC_URL", "http://localhost:4000")
    "#{base}/api/v1/orgs/#{dom.organization.key}/domains/#{dom.key}/brand/icon"
  end
end
