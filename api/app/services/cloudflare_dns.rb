require "net/http"
require "json"

# Writes inbox2's required DNS records into a Cloudflare zone using a customer-
# supplied API token (scoped Zone · DNS · Edit). The token is used transiently
# and never stored.
#
# Records are upserted idempotently so a re-run is a no-op:
#   - MX / DKIM CNAME → enforced to inbox2's values (created or corrected).
#   - SPF TXT         → our include merged into any existing v=spf1 record.
#   - DMARC TXT       → created only if absent (never clobber a custom policy).
#
# The DKIM CNAME is forced to DNS-only (proxied:false): a proxied CNAME resolves
# to Cloudflare's edge IPs instead of the target, so DKIM never verifies — the
# single most common manual-setup failure.
class CloudflareDns
  API = "https://api.cloudflare.com/client/v4".freeze
  MAIL_DOMAIN = DnsRecordsSerializer::MAIL_DOMAIN

  class Error < StandardError; end

  def initialize(token)
    @token = token.to_s.strip
    raise Error, "Missing Cloudflare API token" if @token.empty?
  end

  # Find the zone + upsert every required record. Returns
  # { zone:, records: [{ name:, type:, action: created|updated|kept }] }.
  def apply(domain_record)
    domain = domain_record.name
    zone_id, zone_name = zone_for(domain)
    records = DnsRecordsSerializer.required_records(domain).map { |rec| upsert(zone_id, rec) }
    { zone: zone_name, records: records }
  end

  private

  # Cloudflare zones are registrable domains, so walk up the labels — a subdomain
  # domain (mail.example.com) still resolves to the example.com zone.
  def zone_for(domain)
    parts = domain.split(".")
    (0..(parts.length - 2)).each do |i|
      name = parts[i..].join(".")
      zone = get("/zones", name: name, status: "active").first
      return [zone["id"], zone["name"]] if zone
    end
    raise Error, "#{domain} isn’t in this Cloudflare account. Check that the domain is added to Cloudflare and that the token belongs to the right account."
  end

  def upsert(zone_id, rec)
    # A CNAME to itself is invalid ("content cannot reference itself"). This
    # happens only when the domain IS the mail service domain (inbox2.com), whose
    # _domainkey holds the real DKIM TXT key — there's nothing to CNAME. Skip it.
    return { name: rec[:host], type: rec[:type], action: "skipped" } if rec[:type] == "CNAME" && host_eq?(rec[:host], rec[:value])

    existing = get("/zones/#{zone_id}/dns_records", type: rec[:type], name: rec[:host])
    action =
      case classify(rec)
      when :dmarc then upsert_dmarc(zone_id, rec, existing)
      when :spf   then upsert_spf(zone_id, rec, existing)
      when :mx    then upsert_match(zone_id, rec, existing) { |e| host_eq?(e["content"], rec[:value]) && e["priority"] == rec[:priority] }
      when :dkim  then upsert_match(zone_id, rec, existing) { |e| host_eq?(e["content"], rec[:value]) && e["proxied"] == false }
      end
    { name: rec[:host], type: rec[:type], action: action }
  end

  # Create-if-absent by content match; update the closest existing record if one
  # of the same type+name exists but doesn't already satisfy the block.
  def upsert_match(zone_id, rec, existing)
    return "kept" if existing.any? { |e| yield(e) }

    stale = existing.find { |e| record_family?(e, rec) }
    if stale
      put("/zones/#{zone_id}/dns_records/#{stale['id']}", body_for(rec))
      "updated"
    else
      post("/zones/#{zone_id}/dns_records", body_for(rec))
      "created"
    end
  end

  def upsert_dmarc(zone_id, rec, existing)
    return "kept" if existing.any? { |e| txt(e).start_with?("v=DMARC1") }

    post("/zones/#{zone_id}/dns_records", body_for(rec))
    "created"
  end

  def upsert_spf(zone_id, rec, existing)
    spf = existing.find { |e| txt(e).start_with?("v=spf1") }
    return (post("/zones/#{zone_id}/dns_records", body_for(rec)) && "created") if spf.nil?

    merged = merge_spf(txt(spf))
    return "kept" if merged == txt(spf)

    put("/zones/#{zone_id}/dns_records/#{spf['id']}", body_for(rec.merge(value: merged)))
    "updated"
  end

  # Cloudflare returns TXT content wrapped in quotes ("v=spf1 ... ~all"); on
  # 2026-11-08 the bare start_with? missed husttle.com's live SPF and DMARC and
  # created a second record of each, which makes both invalid for receivers.
  def txt(record)
    record["content"].to_s.strip.delete_prefix('"').delete_suffix('"')
  end

  def classify(rec)
    return :mx if rec[:type] == "MX"
    return :dkim if rec[:type] == "CNAME"

    rec[:host].start_with?("_dmarc.") ? :dmarc : :spf
  end

  # A record we may overwrite: same type; for CNAME any record at that name, for
  # SPF/MX we already filtered in the specific handlers so this is only reached
  # for MX/DKIM via upsert_match.
  def record_family?(existing, rec)
    existing["type"] == rec[:type]
  end

  # Add our include to an existing SPF record, just before the trailing all-
  # mechanism (~all/-all/?all/+all/all), or at the end if there is none.
  def merge_spf(spf)
    include = "include:_spf.#{MAIL_DOMAIN}"
    return spf if spf.include?(include)

    if spf =~ /\s[~\-?+]?all\b/
      spf.sub(/\s([~\-?+]?all\b)/, " #{include} \\1")
    else
      "#{spf} #{include}"
    end
  end

  def body_for(rec)
    body = { type: rec[:type], name: rec[:host], content: rec[:value], ttl: 1 }
    body[:priority] = rec[:priority] if rec[:priority]
    body[:proxied] = false if rec[:type] == "CNAME" # DKIM must be DNS-only
    body
  end

  def host_eq?(a, b)
    a.to_s.chomp(".").casecmp?(b.to_s.chomp("."))
  end

  # ── HTTP ────────────────────────────────────────────────────────────────
  def get(path, **query)
    uri = URI("#{API}#{path}")
    uri.query = URI.encode_www_form(query) unless query.empty?
    result(send_request(Net::HTTP::Get.new(uri), uri))
  end

  def post(path, body)
    result(send_request(json_request(Net::HTTP::Post, path, body), URI("#{API}#{path}")))
  end

  def put(path, body)
    result(send_request(json_request(Net::HTTP::Put, path, body), URI("#{API}#{path}")))
  end

  def json_request(klass, path, body)
    req = klass.new(URI("#{API}#{path}"))
    req["Content-Type"] = "application/json"
    req.body = body.to_json
    req
  end

  def send_request(req, uri)
    req["Authorization"] = "Bearer #{@token}"
    req["Accept"] = "application/json"
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 8, read_timeout: 15) { |http| http.request(req) }
  rescue StandardError => e
    raise Error, "Couldn’t reach Cloudflare: #{e.message}"
  end

  def result(res)
    json = begin
      JSON.parse(res.body)
    rescue StandardError
      {}
    end
    unless json["success"]
      raise Error, error_message(res.code, Array(json["errors"]).map { |e| e["message"] }.join("; "))
    end
    json["result"]
  end

  def error_message(code, detail)
    return "Cloudflare rejected the token — give it Zone · DNS · Edit permission for this domain." if %w[401 403].include?(code.to_s)

    detail.presence || "Cloudflare returned an error (HTTP #{code})."
  end
end
