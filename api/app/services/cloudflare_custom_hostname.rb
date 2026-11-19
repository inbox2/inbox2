require "net/http"
require "json"

# Cloudflare-for-SaaS "custom hostnames": lets us terminate TLS for a customer's
# tracking host (track.tuli.com) on the inbox2 Cloudflare zone. The customer's
# DNS-only CNAME (track.tuli.com -> visit.inbox2.com) both validates the DV cert and
# routes the pixel request to us.
#
# Platform-scoped (our zone + token), NOT the customer token used by CloudflareDns.
# Configured via ENV; when unset this is a no-op (enabled? == false) so dev/self-
# host deployments still function on the inbox2 default host — only custom-host
# TLS is unavailable.
# ponytail: happy-path Cloudflare-for-SaaS only. If we ever front tracking with a
# non-CF edge, add an ACME/Caddy-on-demand provider behind the same interface.
class CloudflareCustomHostname
  API = "https://api.cloudflare.com/client/v4".freeze

  class Error < StandardError; end

  def self.enabled?
    ENV["CLOUDFLARE_API_TOKEN"].present? && ENV["CLOUDFLARE_TRACKING_ZONE_ID"].present?
  end

  def initialize(token: ENV["CLOUDFLARE_API_TOKEN"], zone_id: ENV["CLOUDFLARE_TRACKING_ZONE_ID"])
    @token = token.to_s
    @zone_id = zone_id.to_s
  end

  # Ensure a custom hostname exists for `hostname`; returns its CF id (idempotent).
  def ensure(hostname)
    return nil unless self.class.enabled?

    existing = list(hostname).first
    return existing["id"] if existing

    res = post("/zones/#{@zone_id}/custom_hostnames", {
      hostname: hostname,
      ssl: { method: "http", type: "dv", settings: { min_tls_version: "1.2" } }
    })
    res["id"]
  end

  # => { active: bool, ssl_status: "pending_validation"|"active"|..., raw: {...} }
  def status(hostname_id)
    return { active: false, ssl_status: "unconfigured" } if hostname_id.blank? || !self.class.enabled?

    res = get("/zones/#{@zone_id}/custom_hostnames/#{hostname_id}")
    ssl = res.dig("ssl", "status")
    { active: ssl == "active" && res["status"] == "active", ssl_status: ssl, raw: res }
  end

  def delete(hostname_id)
    return if hostname_id.blank? || !self.class.enabled?
    request(Net::HTTP::Delete, "/zones/#{@zone_id}/custom_hostnames/#{hostname_id}")
  rescue Error => e
    Rails.logger.warn("[CloudflareCustomHostname] delete #{hostname_id} failed: #{e.message}")
  end

  private

  def list(hostname)
    get("/zones/#{@zone_id}/custom_hostnames", hostname: hostname) || []
  end

  def get(path, **query)
    uri = URI("#{API}#{path}")
    uri.query = URI.encode_www_form(query) unless query.empty?
    result(request(Net::HTTP::Get, path, uri: uri))
  end

  def post(path, body)
    result(request(Net::HTTP::Post, path, body: body))
  end

  def request(klass, path, uri: URI("#{API}#{path}"), body: nil)
    req = klass.new(uri)
    req["Authorization"] = "Bearer #{@token}"
    req["Accept"] = "application/json"
    if body
      req["Content-Type"] = "application/json"
      req.body = body.to_json
    end
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 8, read_timeout: 15) { |http| http.request(req) }
  rescue StandardError => e
    raise Error, "Couldn’t reach Cloudflare: #{e.message}"
  end

  def result(res)
    json = JSON.parse(res.body) rescue {}
    raise Error, Array(json["errors"]).map { |e| e["message"] }.join("; ").presence || "Cloudflare error HTTP #{res.code}" unless json["success"]
    json["result"]
  end
end
