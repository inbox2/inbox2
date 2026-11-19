require "net/http"
require "uri"

# Brand lookup for a sender domain (docs/plans/lore.md §4b Imagery): fetches the
# homepage server-side and reads name / icon / og:image / theme-color from its
# <head>. SSRF-guarded (PrivateAddressGuard, pinned IP) on every hop; size- and
# time-bounded; no cookies. Image URLs come back as image-proxy paths so the
# browser never contacts the brand's domain. Never raises: a failure is an
# all-null Brand, cached for a day (successes for 30).
class BrandFetcher
  MAX_HTML = 512 * 1024
  TIMEOUT = 5
  MAX_REDIRECTS = 3
  SUCCESS_TTL = 30.days
  FAILURE_TTL = 1.day
  USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " \
               "(KHTML, like Gecko) Chrome/126.0 Safari/537.36".freeze
  HOSTNAME = /\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/
  # Personal mailbox providers: the domain says nothing about the sender's brand.
  FREEMAIL = %w[
    gmail.com googlemail.com outlook.com hotmail.com live.com msn.com yahoo.com ymail.com
    icloud.com me.com mac.com aol.com proton.me protonmail.com gmx.com gmx.net gmx.de
    mail.com zoho.com yandex.com hey.com fastmail.com
  ].to_set.freeze
  PROXY_PATH = "/api/v1/image-proxy".freeze

  Brand = Struct.new(:domain, :name, :icon_url, :image_url, :theme_color, keyword_init: true) do
    def empty? = [name, icon_url, image_url, theme_color].all?(&:nil?)
  end

  # Downcased, www.-stripped hostname, or nil when it isn't a valid one.
  def self.normalize(raw)
    domain = raw.to_s.strip.downcase.delete_suffix(".").delete_prefix("www.")
    domain.match?(HOSTNAME) ? domain : nil
  end

  # Cached lookup for a normalized domain.
  def self.lookup(domain)
    return Brand.new(domain: domain) if FREEMAIL.include?(domain)

    key = "brand/v2/#{domain}" # v2: re-try failures cached before the IPv4-first fix
    if (cached = Rails.cache.read(key))
      return Brand.new(**cached.symbolize_keys)
    end

    brand = new(domain).call
    Rails.cache.write(key, brand.to_h, expires_in: brand.empty? ? FAILURE_TTL : SUCCESS_TTL)
    brand
  end

  def self.proxy_url(url) = "#{PROXY_PATH}?url=#{ERB::Util.url_encode(url)}"

  def initialize(domain)
    @domain = domain
  end

  def call
    html, final_url = fetch("https://#{@domain}/")
    return Brand.new(domain: @domain) unless html

    parse(html, final_url)
  rescue StandardError => e
    Rails.logger.warn("BrandFetcher #{@domain}: #{e.class}: #{e.message}")
    Brand.new(domain: @domain)
  end

  private

  def parse(html, base)
    doc = Nokogiri::HTML(html)
    meta = ->(*keys) { keys.lazy.filter_map { |k| doc.at_css(%(meta[property="#{k}"], meta[name="#{k}"]))&.[]("content")&.strip.presence }.first }

    name = meta.call("og:site_name") || doc.at_css("title")&.text&.squish.presence
    image = absolute(meta.call("og:image", "og:image:url", "twitter:image", "twitter:image:src"), base)
    icon = best_icon(doc, base) || absolute("/favicon.ico", base)

    Brand.new(domain: @domain, name: name&.truncate(120),
              icon_url: icon && self.class.proxy_url(icon),
              image_url: image && self.class.proxy_url(image),
              theme_color: hex_color(meta.call("theme-color")))
  end

  # Largest declared `sizes` wins; apple-touch-icon defaults to 180, plain icons to 16.
  def best_icon(doc, base)
    doc.css("link[rel][href]").filter_map do |link|
      rel = link["rel"].downcase.split
      next unless rel.include?("icon") || rel.include?("apple-touch-icon")

      url = absolute(link["href"], base) or next
      sizes = link["sizes"].to_s.downcase
      dim = sizes.include?("any") ? 512 : sizes.scan(/(\d+)x\d+/).flatten.map(&:to_i).max
      [url, dim || (rel.include?("apple-touch-icon") ? 180 : 16)]
    end.max_by(&:last)&.first
  end

  # Absolute http(s) URL or nil.
  def absolute(href, base)
    return nil if href.blank?

    uri = URI.join(base, href.strip)
    uri.is_a?(URI::HTTP) ? uri.to_s : nil
  rescue URI::Error
    nil
  end

  def hex_color(value)
    case value.to_s.strip.downcase
    when /\A#([0-9a-f]{6})\z/ then "##{$1}"
    when /\A#([0-9a-f])([0-9a-f])([0-9a-f])\z/ then "##{$1 * 2}#{$2 * 2}#{$3 * 2}"
    end
  end

  # SSRF-guarded GET following redirects; [html, final_url] or nil.
  def fetch(url, redirects_left = MAX_REDIRECTS)
    pinned = PrivateAddressGuard.pinned_url(url)
    return nil unless pinned

    uri, ip = pinned
    response, body = get(uri, ip)
    case response
    when Net::HTTPSuccess
      [body, uri.to_s]
    when Net::HTTPRedirection
      location = response["Location"]
      return nil unless location && redirects_left.positive?

      fetch(URI.join(uri.to_s, location).to_s, redirects_left - 1)
    end
  end

  # One hop, socket pinned to the validated IP, body read up to MAX_HTML.
  # Returns [response, body]. Seam for specs.
  def get(uri, ip)
    http = Net::HTTP.new(uri.host, uri.port)
    http.ipaddr = ip # SNI + Host header stay uri.host
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = TIMEOUT
    http.read_timeout = TIMEOUT

    request = Net::HTTP::Get.new(uri, "User-Agent" => USER_AGENT, "Accept" => "text/html,application/xhtml+xml")
    body = +""
    response = nil
    catch(:enough) do
      http.request(request) do |res|
        response = res
        next unless res.is_a?(Net::HTTPSuccess)

        res.read_body do |chunk|
          body << chunk
          throw :enough if body.bytesize >= MAX_HTML
        end
      end
    end
    [response, body.byteslice(0, MAX_HTML)]
  end
end
