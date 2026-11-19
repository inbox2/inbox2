require "net/http"
require "uri"
require "json"

# Looks up the current weather for a client IP — used by the Bridge morning brief,
# which appends a short weather line. Two no-key upstreams: ip-api.com for IP→lat/lon
# geolocation, then Open-Meteo for the current conditions. Time-bounded and fully
# fail-safe: any error (private/unroutable IP, upstream down, timeout) returns nil so
# the caller simply omits the weather line. Results are cached briefly per location.
class WeatherService
  Result = Struct.new(:short, :temp_c, :code, :place, keyword_init: true)

  TIMEOUT = 4
  GEO_CACHE_TTL = 1.hour
  WEATHER_CACHE_TTL = 10.minutes

  # WMO weather-interpretation codes → short human label. Single-sourced here so the
  # phrasing can't drift; grouped to the words people actually say out loud.
  CODE_LABELS = {
    0 => "clear",
    1 => "mainly clear", 2 => "partly cloudy", 3 => "cloudy",
    45 => "foggy", 48 => "foggy",
    51 => "drizzling", 53 => "drizzling", 55 => "drizzling",
    56 => "freezing drizzle", 57 => "freezing drizzle",
    61 => "rainy", 63 => "rainy", 65 => "heavy rain",
    66 => "freezing rain", 67 => "freezing rain",
    71 => "snowy", 73 => "snowy", 75 => "heavy snow", 77 => "snow grains",
    80 => "rain showers", 81 => "rain showers", 82 => "heavy rain showers",
    85 => "snow showers", 86 => "snow showers",
    95 => "thunderstorms", 96 => "thunderstorms with hail", 99 => "thunderstorms with hail"
  }.freeze

  def self.for_ip(ip)
    new(ip).call
  end

  def initialize(ip)
    @ip = ip.to_s.strip
  end

  def call
    geo = geolocate
    return nil unless geo

    weather = current_weather(geo[:lat], geo[:lon])
    return nil unless weather

    Result.new(
      short: build_short(weather[:temp_c], weather[:code], geo[:place]),
      temp_c: weather[:temp_c],
      code: weather[:code],
      place: geo[:place]
    )
  rescue StandardError => e
    Rails.logger.warn("WeatherService #{@ip}: #{e.class}: #{e.message}")
    nil
  end

  private

  # IP → { lat, lon, place } via ip-api.com (free tier is HTTP-only). Returns nil for
  # private/unroutable IPs (status != "success").
  def geolocate
    Rails.cache.fetch("weather:geo:#{@ip}", expires_in: GEO_CACHE_TTL) do
      data = get_json(URI("http://ip-api.com/json/#{@ip}?fields=status,lat,lon,city,country"))
      next nil unless data && data["status"] == "success" && data["lat"] && data["lon"]

      { lat: data["lat"].to_f, lon: data["lon"].to_f, place: data["city"].presence }
    end
  end

  # lat/lon → { temp_c, code } via Open-Meteo (no key). Cached per rounded location.
  def current_weather(lat, lon)
    key = format("weather:now:%.2f:%.2f", lat, lon)
    Rails.cache.fetch(key, expires_in: WEATHER_CACHE_TTL) do
      uri = URI("https://api.open-meteo.com/v1/forecast")
      uri.query = URI.encode_www_form(
        latitude: lat, longitude: lon, current: "temperature_2m,weather_code"
      )
      data = get_json(uri)
      current = data && data["current"]
      next nil unless current && current["temperature_2m"]

      { temp_c: current["temperature_2m"].round, code: current["weather_code"].to_i }
    end
  end

  # "Currently 14°C and cloudy in Amsterdam." — drops the condition/place gracefully
  # when either is unknown.
  def build_short(temp_c, code, place)
    label = CODE_LABELS[code]
    condition = label ? " and #{label}" : ""
    where = place ? " in #{place}" : ""
    "Currently #{temp_c}°C#{condition}#{where}."
  end

  def get_json(uri)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
      open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.get(uri.request_uri, "User-Agent" => "inbox2-weather/1.0")
    end
    return nil unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end
end
