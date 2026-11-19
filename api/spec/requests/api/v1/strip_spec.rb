require "rails_helper"

# Touch Strip feeds + synced layout (docs/Touch-Strip.md). Upstreams are stubbed
# at StripFeeds' two seams: get_json (Yahoo / Open-Meteo / ip-api) and
# fetch_feed_body (RSS). The feed endpoints are public; the layout needs a session.
RSpec.describe "Api::V1::Strip", type: :request do
  let(:user) { create(:user, username: "stripuser") }
  let(:json) { JSON.parse(response.body) }

  def chart(symbol, price:, prev:)
    { "chart" => { "result" => [{
      "meta" => { "symbol" => symbol, "shortName" => "#{symbol} Inc", "regularMarketPrice" => price,
                  "chartPreviousClose" => prev, "currency" => "USD" },
      "indicators" => { "quote" => [{ "close" => [prev, nil, price] }] }
    }] } }
  end

  describe "GET /api/v1/strip/quotes" do
    it "returns quotes with day change and a sparkline, unauthenticated" do
      allow(StripFeeds).to receive(:get_json) { |uri| chart(uri.path.split("/").last, price: 110.0, prev: 100.0) }
      get "/api/v1/strip/quotes", params: { symbols: "AAPL, BTC-EUR" }

      expect(response).to have_http_status(:ok)
      expect(json["quotes"].map { |q| q["symbol"] }).to eq(%w[AAPL BTC-EUR])
      expect(json["quotes"].first).to include("price" => 110.0, "change_pct" => 10.0, "spark" => [100.0, 110.0])
    end

    it "drops symbols an upstream can't resolve" do
      allow(StripFeeds).to receive(:get_json).and_return(nil)
      get "/api/v1/strip/quotes", params: { symbols: "NOPE" }

      expect(response).to have_http_status(:ok)
      expect(json["quotes"]).to eq([])
    end

    it "rejects a missing or malformed symbol list" do
      get "/api/v1/strip/quotes", params: { symbols: "../etc/passwd" }
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "GET /api/v1/strip/symbols" do
    it "returns ticker matches" do
      allow(StripFeeds).to receive(:get_json).and_return(
        "quotes" => [{ "symbol" => "ASML.AS", "longname" => "ASML Holding N.V.", "quoteType" => "EQUITY", "exchDisp" => "Amsterdam" }]
      )
      get "/api/v1/strip/symbols", params: { q: "asml" }

      expect(response).to have_http_status(:ok)
      expect(json["matches"]).to eq([{ "symbol" => "ASML.AS", "name" => "ASML Holding N.V.", "kind" => "EQUITY", "exchange" => "Amsterdam" }])
    end

    it "requires a query" do
      get "/api/v1/strip/symbols"
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "GET /api/v1/strip/places" do
    it "returns places with their IANA zone" do
      allow(StripFeeds).to receive(:get_json).and_return(
        "results" => [{ "name" => "Lisbon", "admin1" => "Lisbon", "country" => "Portugal",
                        "latitude" => 38.7, "longitude" => -9.1, "timezone" => "Europe/Lisbon" }]
      )
      get "/api/v1/strip/places", params: { q: "lisbon" }

      expect(response).to have_http_status(:ok)
      expect(json["places"].first).to include("name" => "Lisbon", "timezone" => "Europe/Lisbon")
    end

    it "rejects an overlong query" do
      get "/api/v1/strip/places", params: { q: "x" * 61 }
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "GET /api/v1/strip/weather" do
    let(:forecast) do
      { "current" => { "temperature_2m" => 18.4, "weather_code" => 61, "is_day" => 1 },
        "daily" => { "temperature_2m_max" => [19.6], "temperature_2m_min" => [11.8] },
        "hourly" => { "time" => %w[2026-09-29T14:00 2026-09-29T15:00], "temperature_2m" => [18, 17], "weather_code" => [61, 3] },
        "minutely_15" => { "time" => %w[2026-09-29T14:00 2026-09-29T14:15], "precipitation" => [0.0, 0.4] } }
    end

    it "forecasts for explicit coordinates" do
      allow(StripFeeds).to receive(:get_json).and_return(forecast)
      get "/api/v1/strip/weather", params: { lat: "52.37", lon: "4.89", place: "Amsterdam" }

      expect(response).to have_http_status(:ok)
      expect(json["forecast"]).to include("place" => "Amsterdam", "temp_c" => 18, "high_c" => 20, "low_c" => 12, "is_day" => true)
      expect(json["forecast"]["hourly"]).to eq([{ "time" => "2026-09-29T15:00", "temp_c" => 17, "code" => 3 }])
      expect(json["forecast"]["rain"].last).to eq("time" => "2026-09-29T14:15", "mm" => 0.4)
    end

    it "falls back to the caller's IP location" do
      allow(StripFeeds).to receive(:get_json) do |uri|
        uri.host == "ip-api.com" ? { "status" => "success", "city" => "Utrecht", "lat" => 52.09, "lon" => 5.12 } : forecast
      end
      get "/api/v1/strip/weather", headers: { "CF-Connecting-IP" => "203.0.113.9" }

      expect(response).to have_http_status(:ok)
      expect(json["forecast"]["place"]).to eq("Utrecht")
    end

    it "rejects out-of-range coordinates" do
      get "/api/v1/strip/weather", params: { lat: "91", lon: "0" }
      expect(response).to have_http_status(:bad_request)
    end

    it "is 503 when the forecast is unavailable" do
      allow(StripFeeds).to receive(:get_json).and_return(nil)
      get "/api/v1/strip/weather", params: { lat: "52.37", lon: "4.89" }
      expect(response).to have_http_status(:service_unavailable)
    end
  end

  describe "GET /api/v1/strip/ip" do
    it "returns the caller's IP with country and proxy flag, never its coordinates" do
      allow(StripFeeds).to receive(:get_json).and_return(
        "status" => "success", "country" => "Netherlands", "countryCode" => "NL", "city" => "Amsterdam",
        "isp" => "Ziggo", "proxy" => false, "lat" => 52.37, "lon" => 4.89
      )
      get "/api/v1/strip/ip", headers: { "CF-Connecting-IP" => "203.0.113.9" }

      expect(response).to have_http_status(:ok)
      expect(json["ip"]).to eq("ip" => "203.0.113.9", "country" => "Netherlands", "country_code" => "NL",
                               "city" => "Amsterdam", "isp" => "Ziggo", "proxy" => false)
    end

    it "still returns the bare IP when geolocation fails" do
      allow(StripFeeds).to receive(:get_json).and_return(nil)
      get "/api/v1/strip/ip", headers: { "CF-Connecting-IP" => "203.0.113.9" }

      expect(response).to have_http_status(:ok)
      expect(json["ip"]).to include("ip" => "203.0.113.9", "country" => nil)
    end
  end

  describe "GET /api/v1/strip/news" do
    let(:rss) do
      <<~XML
        <?xml version="1.0"?>
        <rss version="2.0"><channel><title>Example News</title>
          <item><title>Older</title><link>https://example.com/1</link><pubDate>Mon, 28 Sep 2026 08:00:00 GMT</pubDate></item>
          <item><title>Newer</title><link>https://example.com/2</link><pubDate>Tue, 29 Sep 2026 08:00:00 GMT</pubDate></item>
          <item><title>Scripted</title><link>javascript:alert(1)</link></item>
        </channel></rss>
      XML
    end

    it "merges feed items newest-first and drops non-http links" do
      allow(StripFeeds).to receive(:fetch_feed_body).and_return(rss)
      get "/api/v1/strip/news", params: { feeds: ["https://example.com/rss"] }

      expect(response).to have_http_status(:ok)
      expect(json["headlines"].map { |h| h["title"] }).to eq(%w[Newer Older])
      expect(json["headlines"].first).to include("source" => "Example News", "url" => "https://example.com/2")
    end

    it "parses Atom feeds" do
      atom = '<feed xmlns="http://www.w3.org/2005/Atom"><title>Atomic</title><entry><title>Hello</title>' \
             '<link href="https://example.org/a"/><updated>2026-09-29T08:00:00Z</updated></entry></feed>'
      allow(StripFeeds).to receive(:fetch_feed_body).and_return(atom)
      get "/api/v1/strip/news", params: { feeds: ["https://example.org/atom"] }

      expect(json["headlines"]).to eq([{ "feed" => "https://example.org/atom", "source" => "Atomic", "title" => "Hello", "url" => "https://example.org/a",
                                         "published_at" => "2026-09-29T08:00:00Z" }])
    end

    it "refuses to fetch a private address (SSRF)" do
      get "/api/v1/strip/news", params: { feeds: ["http://169.254.169.254/latest/meta-data"] }

      expect(response).to have_http_status(:ok)
      expect(json["headlines"]).to eq([])
    end

    it "requires http(s) feed URLs" do
      get "/api/v1/strip/news", params: { feeds: ["file:///etc/passwd"] }
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "account/touch-strip" do
    let(:layout) do
      { items: %w[clocks stocks], clocks: [{ label: "Tokyo", tz: "Asia/Tokyo" }],
        stocks: [{ symbol: "AAPL", weight: 2 }], crypto: %w[BTC], options: { crypto_currency: "EUR" } }
    end

    it "saves and returns the layout, dropping keys outside the allow-list" do
      put "/api/v1/account/touch-strip", params: { touch_strip: layout.merge(evil: "x") }, headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["touch_strip"]).to include("items" => %w[clocks stocks], "crypto" => %w[BTC])
      expect(json["touch_strip"]).not_to have_key("evil")

      get "/api/v1/account/touch-strip", headers: auth_headers(user)
      expect(json["touch_strip"]["clocks"]).to eq([{ "label" => "Tokyo", "tz" => "Asia/Tokyo" }])
    end

    it "returns nulls for a strip that was never saved" do
      get "/api/v1/account/touch-strip", headers: auth_headers(user)
      expect(json["touch_strip"]["items"]).to be_nil
    end

    it "rejects unknown widgets" do
      put "/api/v1/account/touch-strip", params: { touch_strip: { items: %w[clocks bogus] } }, headers: auth_headers(user), as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "requires a session" do
      get "/api/v1/account/touch-strip"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
