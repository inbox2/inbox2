module Api
  module V1
    # Touch Strip (docs/Touch-Strip.md): the bottom bar's data feeds + its synced
    # layout. The feeds are public like WeatherController — they expose no tenant
    # data, and the standalone desktop (local channels only) has no API session —
    # so they're throttled per IP instead (config/initializers/rack_attack.rb).
    # The layout lives on the user, so those two actions keep auth.
    class StripController < BaseController
      skip_before_action :authenticate_user!, only: %i[quotes symbols places weather ip news]

      # GET /api/v1/strip/quotes?symbols=AAPL,ASML.AS,BTC-EUR
      def quotes
        symbols = list_param(:symbols).select { |s| s.match?(StripFeeds::SYMBOL) }.uniq.first(StripFeeds::MAX_SYMBOLS)
        return bad_request("symbols required") if symbols.empty?

        render json: StripSerializers::Quote.new(StripFeeds.quotes(symbols)).serialize
      end

      # GET /api/v1/strip/symbols?q=asml — ticker picker search.
      def symbols
        query = search_query
        return bad_request("q required") unless query

        render json: StripSerializers::Match.new(StripFeeds.symbol_search(query)).serialize
      end

      # GET /api/v1/strip/places?q=lisbon — city picker (weather + clocks: carries the IANA zone).
      def places
        query = search_query
        return bad_request("q required") unless query

        render json: StripSerializers::Place.new(StripFeeds.places(query)).serialize
      end

      # GET /api/v1/strip/weather?lat=52.37&lon=4.89&place=Amsterdam
      # Without lat/lon: wherever the caller's IP geolocates.
      def weather
        lat, lon, place = coordinates
        return bad_request("lat/lon out of range") if lat == :invalid

        forecast = lat && StripFeeds.forecast(lat, lon, place)
        return render json: ErrorSerializer.serialize("Weather unavailable", status: 503), status: :service_unavailable unless forecast

        render json: StripSerializers::Forecast.new(forecast).serialize
      end

      # GET /api/v1/strip/ip
      def ip
        render json: StripSerializers::IpInfo.new(StripFeeds.ip_info(client_ip)).serialize
      end

      # GET /api/v1/strip/news?feeds[]=https://…&feeds[]=https://…
      def news
        feeds = Array(params[:feeds]).map(&:to_s).select { |u| u.match?(%r{\Ahttps?://}i) && u.length <= 500 }
                                     .uniq.first(StripFeeds::MAX_FEEDS)
        return bad_request("feeds required") if feeds.empty?

        render json: StripSerializers::Headline.new(StripFeeds.news(feeds)).serialize
      end

      # GET /api/v1/account/touch-strip
      def show_config
        render json: StripSerializers::Config.new(current_user).serialize
      end

      # PUT /api/v1/account/touch-strip
      def update_config
        if current_user.update(touch_strip: config_params)
          render json: StripSerializers::Config.new(current_user).serialize
        else
          render json: ErrorSerializer.serialize(current_user.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      private

      def config_params
        params.require(:touch_strip).permit(
          items: [],
          clocks: %i[label tz],
          places: %i[label lat lon current],
          stocks: %i[symbol weight],
          crypto: [],
          feeds: %i[url label],
          options: %i[stock_size crypto_currency]
        ).to_h
      end

      def list_param(key)
        params[key].to_s.split(",").map(&:strip).reject(&:empty?)
      end

      def search_query
        q = params[:q].to_s.strip
        q.length.between?(1, 60) ? q : nil
      end

      # [lat, lon, place] from params, or from the caller's IP when absent.
      def coordinates
        if params[:lat].present? && params[:lon].present?
          lat = Float(params[:lat], exception: false)
          lon = Float(params[:lon], exception: false)
          return [:invalid] unless lat&.between?(-90, 90) && lon&.between?(-180, 180)

          return [lat, lon, params[:place].to_s.strip.first(80).presence]
        end

        info = StripFeeds.ip_info(client_ip)
        [info.lat, info.lon, info.city]
      end

      # The API sits behind Cloudflare's proxy; its header is the visitor.
      def client_ip
        request.headers["CF-Connecting-IP"].presence || request.remote_ip
      end

      def bad_request(message)
        render json: ErrorSerializer.serialize(message, status: 400), status: :bad_request
      end
    end
  end
end
