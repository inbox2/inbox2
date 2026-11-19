require "net/http"
require "uri"
require "json"

# Public, non-tenant data behind the Touch Strip (docs/Touch-Strip.md): market
# quotes, symbol search, weather, place search, the caller's public IP and news
# headlines. No-key upstreams only — Yahoo Finance's chart/search endpoints
# (stocks AND crypto pairs like BTC-EUR, so one path serves both keys),
# Open-Meteo (forecast + geocoding), ip-api.com — plus whatever RSS/Atom feeds
# the user picked, fetched through PrivateAddressGuard.
#
# Every upstream is cached server-side, so a thousand strips polling AAPL cost
# one Yahoo call a minute. Fail-safe throughout: an upstream error yields nil /
# an empty list, never an exception, and failures aren't cached (skip_nil).
module StripFeeds
  extend self

  TIMEOUT = 4
  # Yahoo 403s Ruby's default agent; a browser-shaped UA with our bot page passes.
  USER_AGENT = "Mozilla/5.0 (compatible; inbox2-strip/1.0; +https://inbox2.com/bot)".freeze
  SYMBOL = /\A[A-Za-z0-9.\-^=]{1,20}\z/
  MAX_SYMBOLS = 24
  MAX_FEEDS = 6
  MAX_FEED_BYTES = 2 * 1024 * 1024
  MAX_REDIRECTS = 3
  SPARK_POINTS = 24

  Quote = Struct.new(:symbol, :name, :price, :change_pct, :currency, :spark, keyword_init: true)
  Match = Struct.new(:symbol, :name, :kind, :exchange, keyword_init: true)
  Place = Struct.new(:name, :region, :country, :lat, :lon, :timezone, keyword_init: true)
  Forecast = Struct.new(:place, :temp_c, :code, :is_day, :high_c, :low_c, :hourly, :rain, keyword_init: true)
  IpInfo = Struct.new(:ip, :country, :country_code, :city, :isp, :proxy, :lat, :lon, keyword_init: true)
  Headline = Struct.new(:feed, :source, :title, :url, :published_at, keyword_init: true)

  # ── Quotes (Yahoo chart) ────────────────────────────────────────────────────

  def quotes(symbols)
    symbols.filter_map { |s| quote(s) }
  end

  def quote(symbol)
    Rails.cache.fetch("strip:quote:#{symbol.upcase}", expires_in: 60.seconds, skip_nil: true) do
      uri = URI("https://query1.finance.yahoo.com/v8/finance/chart/#{ERB::Util.url_encode(symbol)}")
      uri.query = URI.encode_www_form(range: "1d", interval: "15m")
      result = get_json(uri)&.dig("chart", "result", 0)
      meta = result&.dig("meta")
      next nil unless meta && meta["regularMarketPrice"]

      price = meta["regularMarketPrice"].to_f
      prev = (meta["chartPreviousClose"] || meta["previousClose"]).to_f
      pct = meta["regularMarketChangePercent"] || (prev.positive? ? (price - prev) / prev * 100 : nil)
      Quote.new(
        symbol: meta["symbol"], name: meta["shortName"] || meta["longName"],
        price: price, change_pct: pct&.to_f&.round(2), currency: meta["currency"],
        spark: downsample(Array(result.dig("indicators", "quote", 0, "close")).compact, SPARK_POINTS)
      )
    end
  end

  def symbol_search(query)
    Rails.cache.fetch("strip:symbols:#{query.downcase}", expires_in: 1.day, skip_nil: true) do
      uri = URI("https://query1.finance.yahoo.com/v1/finance/search")
      uri.query = URI.encode_www_form(q: query, quotesCount: 8, newsCount: 0)
      rows = get_json(uri)&.dig("quotes")
      next nil unless rows

      rows.filter_map do |r|
        next unless r["symbol"]

        Match.new(symbol: r["symbol"], name: r["longname"] || r["shortname"],
                  kind: r["quoteType"], exchange: r["exchDisp"])
      end
    end || []
  end

  # ── Weather + places (Open-Meteo) ───────────────────────────────────────────

  def places(query)
    Rails.cache.fetch("strip:places:#{query.downcase}", expires_in: 1.day, skip_nil: true) do
      uri = URI("https://geocoding-api.open-meteo.com/v1/search")
      uri.query = URI.encode_www_form(name: query, count: 6, language: "en")
      data = get_json(uri)
      next nil unless data

      Array(data["results"]).map do |r|
        Place.new(name: r["name"], region: r["admin1"], country: r["country"],
                  lat: r["latitude"], lon: r["longitude"], timezone: r["timezone"])
      end
    end || []
  end

  # Current conditions, today's range, the next 12 hours and the next 4 hours of
  # rain in 15-minute steps (the strip's "rain from 15:10" line).
  def forecast(lat, lon, place = nil)
    key = format("strip:forecast:%.2f:%.2f", lat, lon)
    result = Rails.cache.fetch(key, expires_in: 10.minutes, skip_nil: true) do
      uri = URI("https://api.open-meteo.com/v1/forecast")
      uri.query = URI.encode_www_form(
        latitude: lat, longitude: lon, timezone: "auto",
        current: "temperature_2m,weather_code,is_day",
        hourly: "temperature_2m,weather_code",
        daily: "temperature_2m_max,temperature_2m_min",
        minutely_15: "precipitation",
        forecast_hours: 13, forecast_minutely_15: 16, forecast_days: 2
      )
      d = get_json(uri)
      next nil unless d && d.dig("current", "temperature_2m")

      hourly = d["hourly"] || {}
      rain = d["minutely_15"] || {}
      Forecast.new(
        temp_c: d.dig("current", "temperature_2m").round,
        code: d.dig("current", "weather_code").to_i,
        is_day: d.dig("current", "is_day") == 1,
        high_c: d.dig("daily", "temperature_2m_max", 0)&.round,
        low_c: d.dig("daily", "temperature_2m_min", 0)&.round,
        hourly: Array(hourly["time"]).each_with_index.drop(1).map do |t, i|
          { time: t, temp_c: hourly.dig("temperature_2m", i)&.round, code: hourly.dig("weather_code", i) }
        end,
        rain: Array(rain["time"]).each_with_index.map { |t, i| { time: t, mm: rain.dig("precipitation", i).to_f } }
      )
    end
    result&.dup&.tap { |f| f.place = place }
  end

  # ── Public IP (ip-api.com; free tier is HTTP-only, fine server-side) ────────

  def ip_info(ip)
    Rails.cache.fetch("strip:ip:#{ip}", expires_in: 1.hour, skip_nil: true) do
      data = get_json(URI("http://ip-api.com/json/#{ERB::Util.url_encode(ip)}?fields=status,country,countryCode,city,isp,proxy,lat,lon"))
      next nil unless data

      ok = data["status"] == "success"
      IpInfo.new(
        ip: ip, country: ok ? data["country"] : nil, country_code: ok ? data["countryCode"] : nil,
        city: ok ? data["city"] : nil, isp: ok ? data["isp"] : nil, proxy: ok && data["proxy"] == true,
        lat: ok ? data["lat"] : nil, lon: ok ? data["lon"] : nil
      )
    end || IpInfo.new(ip: ip, proxy: false)
  end

  # ── News (user-chosen RSS/Atom feeds) ───────────────────────────────────────

  def news(urls)
    urls.first(MAX_FEEDS).flat_map { |u| feed(u) }
        .sort_by { |h| h.published_at || Time.at(0) }.reverse.first(40)
  end

  def feed(url)
    Rails.cache.fetch("strip:feed:#{Digest::SHA256.hexdigest(url)}", expires_in: 10.minutes, skip_nil: true) do
      body = fetch_feed_body(url)
      body && parse_feed(body, url)
    end || []
  end

  # RSS 2.0 (<item>) and Atom (<entry>) — namespaces stripped so one set of
  # selectors covers both. Only http(s) links survive: the client opens them.
  # NONET and no NOENT: external entities are never fetched or expanded (XXE).
  # Recover mode, because real feeds are rarely well-formed.
  def parse_feed(body, url)
    doc = Nokogiri::XML(body) { |c| c.nonet }
    doc.remove_namespaces!
    source = doc.at_xpath("/rss/channel/title | /feed/title")&.text&.strip.presence || URI(url).host
    doc.xpath("//item | //entry").first(20).filter_map do |node|
      title = node.at_xpath("title")&.text&.strip
      link_node = node.at_xpath("link")
      link = (link_node&.[]("href") || link_node&.text).to_s.strip
      next if title.blank? || !link.match?(%r{\Ahttps?://}i)

      date = node.at_xpath("pubDate | published | updated | date")&.text
      Headline.new(feed: url, source: source.truncate(40), title: title.truncate(200), url: link,
                   published_at: (Time.zone.parse(date) rescue nil))
    end
  rescue Nokogiri::XML::SyntaxError, URI::InvalidURIError
    nil
  end

  # SSRF-guarded GET: resolve + pin every hop to a public IP (the image proxy's
  # rule — see PrivateAddressGuard.pinned_url). Seam for specs.
  def fetch_feed_body(url, redirects_left = MAX_REDIRECTS)
    uri, ip = PrivateAddressGuard.pinned_url(url)
    return nil unless uri

    http = Net::HTTP.new(uri.host, uri.port)
    http.ipaddr = ip
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = TIMEOUT
    http.read_timeout = TIMEOUT
    response = http.request(Net::HTTP::Get.new(uri, "User-Agent" => USER_AGENT,
      "Accept" => "application/rss+xml, application/atom+xml, application/xml;q=0.9, */*;q=0.5"))

    case response
    when Net::HTTPRedirection
      location = response["Location"]
      return nil unless location && redirects_left.positive?

      fetch_feed_body(URI.join(uri.to_s, location).to_s, redirects_left - 1)
    when Net::HTTPSuccess
      body = response.body.to_s
      body.bytesize > MAX_FEED_BYTES ? nil : body
    end
  rescue StandardError => e
    Rails.logger.warn("StripFeeds feed #{url}: #{e.class}: #{e.message}")
    nil
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Evenly spaced picks, always keeping the last (latest) value.
  def downsample(values, n)
    return values.map { |v| v.to_f.round(4) } if values.size <= n

    step = (values.size - 1).fdiv(n - 1)
    Array.new(n) { |i| values[(i * step).round].to_f.round(4) }
  end

  # Seam for specs.
  def get_json(uri)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
      open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.get(uri.request_uri, "User-Agent" => USER_AGENT, "Accept" => "application/json")
    end
    return nil unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue StandardError => e
    Rails.logger.warn("StripFeeds #{uri.host}: #{e.class}: #{e.message}")
    nil
  end
end
