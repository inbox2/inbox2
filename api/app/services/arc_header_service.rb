# Generates ARC (Authenticated Received Chain) headers per RFC 8617 (spec 18.2.4).
# ARC preserves upstream authentication results when inbox2 relays/forwards a
# message, so a downstream receiver can trust the original SPF/DKIM/DMARC verdict
# even though forwarding broke them.
#
# Signatures are real RSA-SHA256 over relaxed-canonicalized headers (the same
# central DKIM key as outbound mail; see DkimKey). The ARC-Seal can always be
# signed from the ARC header set alone; the ARC-Message-Signature additionally
# needs the relayed message, so pass `raw_message:` to bind it to the body.
#
# Not yet wired into a forwarding path — available for the forward/relay action.
class ArcHeaderService
  # Headers covered by the ARC-Message-Signature. Kept small + stable so a
  # forwarder that touches other headers doesn't invalidate the signature.
  SIGNED_HEADERS = %w[from to subject date message-id].freeze

  def initialize(organization, instance: 1, key: nil, selector: nil)
    @organization = organization
    @instance = instance
    @key = key || DkimKey.rsa
    @selector = selector || DkimKey.selector
    @domain = organization.default_domain&.name
  end

  # => { "ARC-Authentication-Results" =>, "ARC-Message-Signature" =>, "ARC-Seal" => }
  # prior_arc: [[name, value], ...] ARC headers from earlier instances, included
  # in the seal so the chain is sealed cumulatively.
  def generate_headers(authentication_results:, raw_message: nil, prior_arc: [], timestamp: nil)
    t = (timestamp || Time.current.utc.to_i)
    aar = "i=#{@instance}; #{@domain}; #{authentication_results}"
    ams = build_message_signature(raw_message, t)
    seal = build_seal(aar, ams, prior_arc, t)

    {
      "ARC-Authentication-Results" => aar,
      "ARC-Message-Signature" => ams,
      "ARC-Seal" => seal
    }
  end

  def self.validate_chain(headers)
    arc_seals = headers.select { |k, _| k.downcase == "arc-seal" }
    return { valid: true, chain_length: 0 } if arc_seals.empty?

    instances = arc_seals.values.map { |v| v.match(/i=(\d+)/)[1].to_i rescue 0 }.sort

    # Verify sequential instance numbering
    valid = instances == (1..instances.length).to_a

    {
      valid: valid,
      chain_length: instances.length,
      last_cv: arc_seals.values.last&.match(/cv=(\w+)/)&.captures&.first
    }
  end

  private

  def build_message_signature(raw_message, t)
    headers, body = split_message(raw_message)
    bh = body_hash(body)
    tags = "i=#{@instance}; a=rsa-sha256; c=relaxed/relaxed; d=#{@domain}; " \
           "s=#{@selector}; t=#{t}; h=#{SIGNED_HEADERS.join(':')}; bh=#{bh}; b="

    signed = SIGNED_HEADERS.map { |h| canon_header(h, headers[h]) + "\r\n" }.join
    input = signed + canon_header("arc-message-signature", tags)
    tags + sign(input)
  end

  def build_seal(aar, ams, prior_arc, t)
    cv = @instance == 1 ? "none" : "pass"
    tags = "i=#{@instance}; a=rsa-sha256; t=#{t}; cv=#{cv}; d=#{@domain}; s=#{@selector}; b="

    arc_set = prior_arc.dup
    arc_set << ["arc-authentication-results", aar]
    arc_set << ["arc-message-signature", ams]
    input = arc_set.map { |name, value| canon_header(name, value) + "\r\n" }.join
    input += canon_header("arc-seal", tags)
    tags + sign(input)
  end

  # RSA-SHA256 signature, base64. Empty (logged) when no key is configured — the
  # headers are still well-formed, just unsigned.
  def sign(input)
    unless @key
      Rails.logger.warn("[ArcHeaderService] no DKIM key — ARC headers unsigned")
      return ""
    end
    Base64.strict_encode64(@key.sign(OpenSSL::Digest.new("SHA256"), input))
  end

  def body_hash(body)
    Base64.strict_encode64(OpenSSL::Digest.new("SHA256").digest(canon_body(body)))
  end

  # RFC 6376 §3.4.2 relaxed header canonicalization.
  def canon_header(name, value)
    n = name.to_s.downcase.strip
    v = value.to_s.gsub(/\r?\n/, "").gsub(/[ \t]+/, " ").strip
    "#{n}:#{v}"
  end

  # RFC 6376 §3.4.4 relaxed body canonicalization.
  def canon_body(body)
    b = body.to_s.gsub(/\r?\n/, "\n")
    b = b.gsub(/[ \t]+\n/, "\n")       # strip trailing WSP per line
    b = b.gsub(/[ \t]+/, " ")          # collapse WSP runs
    b = b.gsub(/\n/, "\r\n")           # CRLF line endings
    b = b.sub(/(\r\n)+\z/, "")         # drop trailing empty lines
    b.empty? ? "" : b + "\r\n"
  end

  # Splits a raw RFC 5322 message into an unfolded header map and the body.
  def split_message(raw)
    return [{}, ""] if raw.blank?

    normalized = raw.to_s.gsub(/\r\n/, "\n")
    head, _, body = normalized.partition("\n\n")
    [parse_headers(head), body]
  end

  def parse_headers(head)
    headers = {}
    current_name = nil
    head.each_line do |line|
      line = line.chomp
      if line =~ /\A[ \t]/ && current_name
        headers[current_name] << " " << line.strip
      elsif line =~ /\A([!-9;-~]+):(.*)\z/
        current_name = Regexp.last_match(1).downcase
        headers[current_name] = Regexp.last_match(2).strip
      end
    end
    headers
  end
end
