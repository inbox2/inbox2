require "net/http"
require "uri"

# Fetches a domain's best brand icon: scrapes the homepage for apple-touch-icon /
# <link rel=icon> / og:image, picks the highest-resolution candidate, and returns
# its bytes. SSRF-guarded (PrivateAddressGuard) on every hop, size- and
# time-bounded. Returns a Result or nil.
class FaviconFetcher
  MAX_HTML = 512 * 1024
  MAX_IMAGE = 3 * 1024 * 1024
  TIMEOUT = 6
  MAX_REDIRECTS = 3
  USER_AGENT = "inbox2-favicon/1.0 (+https://inbox2.com/bot)".freeze

  Result = Struct.new(:bytes, :content_type, :source_url, keyword_init: true)

  def initialize(domain)
    @domain = domain.to_s.strip.downcase.sub(%r{\Ahttps?://}, "").split("/").first
  end

  def call
    return nil if @domain.blank?

    base = "https://#{@domain}"
    html = fetch(base)&.first
    candidates = html ? extract_candidates(html, base) : []
    candidates << "#{base}/favicon.ico" # always-available fallback

    candidates.uniq.each do |url|
      body, content_type = fetch(url)
      next if body.blank?

      ct = content_type.to_s.split(";").first
      next unless ct&.start_with?("image/") || url.end_with?(".ico")
      next if body.bytesize > MAX_IMAGE

      return Result.new(bytes: body, content_type: ct.presence || "image/x-icon", source_url: url)
    end
    nil
  rescue StandardError => e
    Rails.logger.warn("FaviconFetcher #{@domain}: #{e.class}: #{e.message}")
    nil
  end

  private

  # Ordered best→worst: apple-touch-icon, then declared icons (by pixel size),
  # then og:image / twitter:image.
  def extract_candidates(html, base)
    found = []

    html.scan(/<link\b[^>]*>/i).each do |tag|
      rel = tag[/rel=["']([^"']+)["']/i, 1].to_s.downcase
      next unless rel.include?("icon")

      href = tag[/href=["']([^"']+)["']/i, 1]
      next if href.blank?

      sizes = tag[/sizes=["']([^"']+)["']/i, 1].to_s
      dim = sizes.scan(/(\d+)x\d+/i).flatten.map(&:to_i).max
      dim ||= rel.include?("apple") ? 180 : 16
      found << [absolute(href, base), dim]
    end

    html.scan(/<meta\b[^>]*>/i).each do |tag|
      key = (tag[/property=["']([^"']+)["']/i, 1] || tag[/name=["']([^"']+)["']/i, 1]).to_s.downcase
      next unless %w[og:image og:image:url twitter:image twitter:image:src].include?(key)

      content = tag[/content=["']([^"']+)["']/i, 1]
      found << [absolute(content, base), 150] if content.present?
    end

    found.compact.sort_by { |(_, dim)| -dim }.map(&:first).compact
  end

  def absolute(href, base)
    return nil if href.blank?
    URI.join(base, href.strip).to_s
  rescue URI::InvalidURIError
    nil
  end

  # SSRF-guarded GET with redirect-following; returns [body, content_type] or nil.
  def fetch(url, redirects = 0)
    return nil if url.blank? || redirects > MAX_REDIRECTS

    # Resolve + validate ONCE and pin the socket to that IP, closing the
    # DNS-rebinding window between the guard check and the connect.
    pinned = PrivateAddressGuard.pinned_url(url)
    return nil unless pinned

    uri, ip = pinned
    http = Net::HTTP.new(uri.host, uri.port)
    http.ipaddr = ip # SNI + Host header stay uri.host
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = TIMEOUT
    http.read_timeout = TIMEOUT

    req = Net::HTTP::Get.new(uri)
    req["User-Agent"] = USER_AGENT
    res = http.request(req)

    case res
    when Net::HTTPSuccess
      [res.body.to_s.byteslice(0, MAX_HTML * 8), res["content-type"]]
    when Net::HTTPRedirection
      fetch(URI.join(url, res["location"]).to_s, redirects + 1)
    end
  rescue StandardError => e
    Rails.logger.debug("FaviconFetcher fetch #{url}: #{e.class}: #{e.message}")
    nil
  end
end
