module Api
  module V1
    # Current weather for the caller's IP — feeds the Bridge morning brief. Public and
    # unauthenticated (it exposes no tenant data and offline-channel clients have no
    # API session). Always 200: when weather can't be resolved, `short` is null and the
    # client simply omits the line.
    class WeatherController < BaseController
      skip_before_action :authenticate_user!, only: :show

      def show
        result = WeatherService.for_ip(request.remote_ip) || WeatherService::Result.new
        render json: WeatherSerializer.new(result).serialize
      end
    end
  end
end
