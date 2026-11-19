# Email open tracking (docs/Open-Tracking.md). Central home for the pixel host,
# URL shape, GIF bytes, and token primitive so nothing about the tracking wire
# format is duplicated across the injector, the pixel controller, and the clients.
module Tracking
  # A local-channel token minted before read secrets (nanoid(22)); a hashed one is 24.
  LEGACY_TOKEN_LENGTH = 22

  # The pixel token for a read secret. ui/desktop/core/src/sync/tracking.rs derives the same.
  def self.token_for(secret)
    Base64.urlsafe_encode64(Digest::SHA256.digest(secret.to_s), padding: false)[0, 24]
  end

  # The inbox2-owned default pixel host (when a domain/channel picks "no custom
  # domain"). Custom hosts (track.tuli.com) resolve to this via a CNAME +
  # Cloudflare-for-SaaS custom hostname, so the route is the same app either way.
  DEFAULT_HOST = ENV.fetch("INBOX2_TRACKING_HOST", "visit.#{DnsRecordsSerializer::MAIL_DOMAIN}").freeze

  # 1x1 transparent GIF, served for every pixel hit (even bad tokens — never leak
  # which tokens are real).
  PIXEL_GIF = Base64.decode64("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7").freeze

  # Known mail-provider image proxies / prefetchers → a render by the provider,
  # not a human. Keyed by a case-insensitive User-Agent substring.
  # ponytail: UA-substring only; add Apple MPP egress-IP ranges when open volume
  # justifies maintaining the list (Apple prefetch UA is a plain Safari string).
  PROXY_UA_MARKERS = {
    "googleimageproxy" => "gmail",
    "yahoomailproxy" => "yahoo",
    "yandeximages" => "yandex",
    "gmailimageproxy" => "gmail"
  }.freeze

  # Email security scanners that prefetch links at delivery time (Microsoft
  # SafeLinks, Proofpoint URLDefense, Mimecast, Barracuda) — a scan, not a human
  # click. Recorded but excluded from the real-click count.
  LINK_BOT_UA_MARKERS = {
    "safelinks" => "safelinks",
    "microsoftpreview" => "safelinks",
    "urldefense" => "proofpoint",
    "mimecast" => "mimecast",
    "barracuda" => "barracuda"
  }.merge(PROXY_UA_MARKERS).freeze

  module_function

  def token
    Nanoid.generate(size: 22)
  end

  # The pixel URL embedded in outgoing HTML. `host` is the resolved tracking host
  # (custom or DEFAULT_HOST). https always — mail clients block mixed content.
  def pixel_url(token, host: DEFAULT_HOST)
    "https://#{host}/o/#{token}.gif"
  end

  # The <img> tag appended just before </body> (or at the end). Zero-size, hidden.
  def pixel_tag(token, host: DEFAULT_HOST)
    %(<img src="#{pixel_url(token, host: host)}" width="1" height="1" alt="" style="display:none;width:1px;height:1px;border:0" />)
  end

  # Appends the pixel to an HTML body once. No-op if the body already carries a
  # pixel for this token (idempotent across recompose/retry).
  def inject(html, token, host: DEFAULT_HOST)
    return html if html.blank? || html.include?("/o/#{token}.gif")
    tag = pixel_tag(token, host: host)
    if html =~ %r{</body>}i
      html.sub(%r{</body>}i, "#{tag}</body>")
    else
      html + tag
    end
  end

  # Classifies a pixel hit's User-Agent → [proxied?, proxy_kind]. A missing UA is
  # treated as a proxy prefetch (real mail clients always send one).
  def classify_proxy(user_agent)
    ua = user_agent.to_s.downcase
    return [true, "unknown"] if ua.blank?
    PROXY_UA_MARKERS.each { |marker, kind| return [true, kind] if ua.include?(marker) }
    [false, nil]
  end

  # Classifies a link click's User-Agent → [bot?, kind]. Missing UA or a known
  # security-scanner UA is a prefetch, not a human click.
  def classify_click_bot(user_agent)
    ua = user_agent.to_s.downcase
    return [true, "unknown"] if ua.blank?
    LINK_BOT_UA_MARKERS.each { |marker, kind| return [true, kind] if ua.include?(marker) }
    [false, nil]
  end

  # The fetcher's real IP, seeing through our edge (CF-Connecting-IP behind
  # Cloudflare, then the leftmost X-Forwarded-For hop, then the peer). Shared by
  # the pixel and link-redirect controllers.
  def client_ip(request)
    cf = request.headers["CF-Connecting-IP"].presence
    return cf if cf

    xff = request.headers["X-Forwarded-For"].to_s.split(",").map(&:strip).reject(&:blank?)
    xff.first || request.remote_ip
  end

  # The click-redirect URL a tracked <a href> is rewritten to.
  def link_url(token, host: DEFAULT_HOST)
    "https://#{host}/l/#{token}"
  end

  # Rewrites every trackable <a href> in the HTML to a click-redirect, yielding
  # each original URL to get its token (the caller creates the TrackedLink row).
  # Identical URLs share one token. Skips non-http(s), mailto/anchors, and our own
  # pixel/redirect links. ponytail: regex over href attributes — good enough for
  # the well-formed HTML our composer emits; swap for Nokogiri if we ever rewrite
  # arbitrary inbound HTML.
  def rewrite_links(html, host: DEFAULT_HOST)
    return html if html.blank?

    seen = {}
    html.gsub(/(<a\b[^>]*?\shref\s*=\s*)(["'])(.*?)\2/i) do
      prefix, quote, url = Regexp.last_match(1), Regexp.last_match(2), Regexp.last_match(3)
      if trackable_link?(url, host)
        token = (seen[url] ||= yield(url))
        "#{prefix}#{quote}#{link_url(token, host: host)}#{quote}"
      else
        "#{prefix}#{quote}#{url}#{quote}"
      end
    end
  end

  def trackable_link?(url, host)
    u = url.to_s.strip
    return false unless u.match?(%r{\Ahttps?://}i)
    return false if u.include?("/o/") || u.include?("/l/")   # our own pixel / redirect
    return false if u.downcase.include?(host.downcase)        # already our tracking host
    true
  end
end
