# Touch Strip payloads (StripController). The data serializers wrap
# StripFeeds' plain Structs, so they include Alba::Resource directly rather than
# inheriting ApplicationSerializer (which assumes a `key`) — same as WeatherSerializer.
module StripSerializers
  class Quote
    include Alba::Resource

    root_key :quote, :quotes
    attributes :symbol, :name, :price, :change_pct, :currency, :spark
  end

  class Match
    include Alba::Resource

    root_key :match, :matches
    attributes :symbol, :name, :kind, :exchange
  end

  class Place
    include Alba::Resource

    root_key :place, :places
    attributes :name, :region, :country, :lat, :lon, :timezone
  end

  class Forecast
    include Alba::Resource

    root_key :forecast
    attributes :place, :temp_c, :code, :is_day, :high_c, :low_c, :hourly, :rain
  end

  # lat/lon stay server-side: the strip shows the IP, not where it geolocates.
  class IpInfo
    include Alba::Resource

    root_key :ip
    attributes :ip, :country, :country_code, :city, :isp, :proxy
  end

  class Headline
    include Alba::Resource

    root_key :headline, :headlines
    # `feed` is the URL it came from, so the client can show the user's own label.
    attributes :feed, :source, :title, :url
    attribute(:published_at) { |h| h.published_at&.utc&.iso8601 }
  end

  # The user's saved layout. Only the allow-listed sections (User::TOUCH_STRIP_KEYS)
  # are echoed; an unset strip comes back as nulls and the client uses its defaults.
  class Config
    include Alba::Resource

    root_key :touch_strip
    User::TOUCH_STRIP_KEYS.each do |section|
      attribute(section) { |user| user.touch_strip&.dig(section.to_s) }
    end
  end
end
