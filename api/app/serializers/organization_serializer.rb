class OrganizationSerializer < ::ApplicationSerializer
  attributes :name, :slug, :timezone, :language, :view_creation_policy, :created_at

  # Team-activity insights switch — via the model's defensive reader so a
  # not-yet-migrated column can't 500 the serializer (defaults to ON).
  attribute :activity_tracking_enabled do |org|
    org.activity_tracking_enabled?
  end

  # IMAP and SMTP access from other mail clients (docs/Mail-Clients.md); off
  # until an admin switches it on.
  attribute :mail_clients_enabled, &:mail_clients_enabled

  # The org's domains (first-class). `domain`/`status`/`dns_*` below are kept as
  # convenience mirrors of the PRIMARY domain for back-compat with single-domain
  # clients; new multi-domain UI reads `domains`.
  # With params[:membership], only the domains that member works on (pool grant,
  # mailbox or send-as) — a scoped member gets no tab, address or DNS state for
  # the others.
  attribute :domains do |org|
    OrganizationSerializer.visible_domains(org, params[:membership]).map { |d| DomainSerializer.new(d).to_h }
  end

  attribute :domain do |org|
    OrganizationSerializer.primary_domain(org, params[:membership])&.name
  end

  attribute :status do |org|
    OrganizationSerializer.primary_domain(org, params[:membership])&.status
  end

  # Billing-lock mirror: true when ANY of the org's domains is locked (over a
  # downgraded plan's limit) — drives the "Locked" badge on the console card.
  attribute :locked do |org|
    org.domains.any?(&:locked?)
  end

  # Effective plan summary so clients can gate plan-only features (e.g. the
  # Spaces / AI-triage paywall) without a separate billing fetch. `tier` is the
  # canonical identity (free-ness is `tier == "free"`); `name` is display only.
  attribute :plan do |org|
    p = org.effective_plan
    { tier: p.tier, name: p.name, price_cents: p.price_cents, ai_triage: p.ai_triage, disk: org.disk_enabled? }
  end

  # What one mail's attachments may add up to before a send is refused. The composer
  # offers a Disk link above it instead of attaching (Disk spec F9).
  attribute :send_attachment_limit_bytes do |org|
    [org.effective_mail_size_limit, OutboundMailPublisher::MAX_ATTACHMENT_BYTES].min
  end

  # icon/logo are stored as internal keys; expose the public brand endpoint that
  # streams them (nil when no asset is set). The square icon resolves upload →
  # favicon, with icon_source telling the client which (so it can show "Re-fetch"
  # only for a favicon, and fall back to initials when both are absent).
  attribute :icon_url do |org|
    org.resolved_icon_key.present? ? OrganizationSerializer.brand_url(org, "icon") : nil
  end

  attribute :icon_source do |org|
    org.icon_source
  end

  attribute :logo_url do |org|
    org.logo_url.present? ? OrganizationSerializer.brand_url(org, "logo") : nil
  end

  # Latest per-record DNS check ({ "mx" =>, "spf" =>, "dmarc" =>, "dkim" => }
  # booleans) so the admin health card shows real record state. nil until checked.
  attribute :dns_checks do |org|
    OrganizationSerializer.primary_domain(org, params[:membership])&.dns_checks.presence
  end

  attribute :dns_checked_at do |org|
    OrganizationSerializer.primary_domain(org, params[:membership])&.dns_checked_at
  end

  def self.visible_domains(org, membership)
    return org.domains if membership.nil? || membership.all_domains_access?

    ids = membership.home_domain_ids
    org.domains.select { |d| ids.include?(d.id) }
  end

  # The single-domain mirror: the org's default domain, or a scoped member's first.
  def self.primary_domain(org, membership)
    return org.default_domain if membership.nil? || membership.all_domains_access?

    visible_domains(org, membership).min_by(&:created_at)
  end

  def self.brand_url(org, kind)
    base = ENV.fetch("API_PUBLIC_URL", "http://localhost:4000")
    # ?v= changes with each upload: the endpoint is cached a day, so a fixed URL kept the old image.
    key = kind == "logo" ? org.logo_url : org.resolved_icon_key
    "#{base}/api/v1/orgs/#{org.key}/brand/#{kind}?v=#{Digest::SHA1.hexdigest(key.to_s)[0, 10]}"
  end
end
