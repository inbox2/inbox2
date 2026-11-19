# DNS setup + verification for a domain's CUSTOM open-tracking host
# (track.tuli.com). The customer adds one CNAME pointing at the inbox2 tracking
# host; TLS for that hostname is provisioned via Cloudflare-for-SaaS
# (CloudflareCustomHostname). Mirrors DnsChecker's shape.
#
# The verna gotcha (verna/CLAUDE.md:259 — CF records "should be proxied"): for a
# tracking CNAME the OPPOSITE is required. If the customer leaves track.tuli.com
# proxied (orange cloud), it resolves to Cloudflare's edge IPs instead of
# following the CNAME to us — CF-for-SaaS can't validate (error 1014) and the
# edge caches the pixel (inflated/one-shot opens). So we detect the proxied state
# and tell the user to set the record to DNS-only (grey cloud).
class TrackingDns
  TARGET = Tracking::DEFAULT_HOST

  # Cloudflare's published edge IPv4 ranges (a proxied record resolves into these).
  CLOUDFLARE_V4 = %w[
    173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22
    141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20
    197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13
    104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
  ].map { |c| IPAddr.new(c) }.freeze

  def initialize(domain_record = nil, host: nil, resolver: DnsResolver.new)
    @host = host || domain_record&.tracking_domain
    @resolver = resolver
  end

  # The one record the customer must add for a custom tracking host.
  def self.required_records(tracking_domain)
    [{ type: "CNAME", host: tracking_domain, value: TARGET, proxied: false, status: Domain::STATUS_PENDING_DNS }]
  end

  # Stateless verify of a bare host (local channels have no Domain row).
  def self.verify_host(host, resolver: DnsResolver.new)
    new(host: host, resolver: resolver).call
  end

  # => { ok:, cname_ok:, proxied:, checks: {...}, error: } ; nil host = using the
  # inbox2 default host (nothing to verify — always ok).
  def call
    host = @host
    return { ok: true, cname_ok: true, proxied: false, checks: {} } if host.blank?

    cname = @resolver.cname(host)
    cname_ok = host_eq?(cname, TARGET)
    proxied = !cname_ok && cloudflare_proxied?(host)

    result = { ok: cname_ok, cname_ok: cname_ok, proxied: proxied, checks: { cname: cname_ok } }
    unless cname_ok
      result[:error] = if proxied
        "#{host} is proxied through Cloudflare (orange cloud). Set the CNAME to DNS-only (grey cloud) so it points at #{TARGET}."
      else
        "#{host} does not yet resolve to #{TARGET}. Add a CNAME (DNS-only) and allow DNS to propagate."
      end
    end
    result
  end

  private

  # A record with no CNAME-to-us but A records inside Cloudflare's ranges is a
  # proxied (orange-cloud) CNAME hiding its target behind the CF edge.
  def cloudflare_proxied?(host)
    @resolver.a(host).any? { |ip| in_cloudflare?(ip) }
  end

  def in_cloudflare?(ip)
    addr = IPAddr.new(ip)
    CLOUDFLARE_V4.any? { |net| net.include?(addr) }
  rescue IPAddr::Error
    false
  end

  def host_eq?(a, b)
    return false if a.nil?
    a.to_s.chomp(".").casecmp?(b.to_s.chomp("."))
  end
end
