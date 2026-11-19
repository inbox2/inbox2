require "net/http"
require "digest"

# The best public picture for an email address, as a remote URL the image proxy
# can fetch (AvatarsController). One chain for every client, resolved server-side
# so neither Gravatar nor the sender's site sees the reader:
#
#   1. Gravatar (SHA-256 of the address; `d=404` when the person has none)
#   2. Google's favicon service for the sender's domain (128px; 404 when the site
#      has none) — reaches sites that block our homepage fetch (LinkedIn). Only
#      the domain goes to Google, from this server.
#   3. the domain's icon from its homepage (BrandFetcher)
#   4. nil → the client draws initials
#
# Freemail domains skip 2 and 3: gmail.com's logo says nothing about the sender.
#
# Meta DM photos (`from_avatar`) and member photos come from their own sources and
# win client-side. ponytail: no BIMI — its logos are SVG, which the mobile image
# decoders can't draw, and the brands that publish one have an apple-touch-icon.
class AvatarResolver
  EMAIL = /\A[^@\s]+@[^@\s]+\z/
  HIT_TTL = 7.days
  MISS_TTL = 1.day
  TIMEOUT = 3

  def self.lookup(raw)
    email = raw.to_s.strip.downcase
    return nil unless email.match?(EMAIL)

    hash = Digest::SHA256.hexdigest(email)
    key = "avatar/v2/#{hash}" # v2: Google favicon step; drops v1 misses
    cached = Rails.cache.read(key)
    return cached.presence if cached

    url = new(email, hash).call
    Rails.cache.write(key, url.to_s, expires_in: url ? HIT_TTL : MISS_TTL)
    url
  end

  def initialize(email, hash)
    @email = email
    @hash = hash
  end

  def call
    gravatar || google_icon || domain_icon
  end

  private

  def gravatar
    url = "https://www.gravatar.com/avatar/#{@hash}?s=160&d=404"
    url if exists?(url)
  end

  def google_icon
    domain = sender_domain or return nil
    url = "https://t1.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON" \
          "&fallback_opts=TYPE,SIZE,URL&url=#{ERB::Util.url_encode("https://#{domain}")}&size=128"
    url if exists?(url)
  end

  def sender_domain
    domain = BrandFetcher.normalize(@email.split("@").last)
    domain unless domain.nil? || BrandFetcher::FREEMAIL.include?(domain)
  end

  # HEAD → 2xx. Seam for specs.
  def exists?(url)
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.head(uri.request_uri).is_a?(Net::HTTPSuccess)
    end
  rescue StandardError => e
    Rails.logger.warn("AvatarResolver #{URI(url).host}: #{e.class}: #{e.message}")
    false
  end

  # BrandFetcher hands back image-proxy paths; unwrap to the remote URL.
  def domain_icon
    domain = sender_domain or return nil
    icon = BrandFetcher.lookup(domain).icon_url or return nil
    CGI.parse(URI(icon).query.to_s)["url"]&.first.presence
  end
end
