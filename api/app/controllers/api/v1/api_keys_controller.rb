module Api
  module V1
    class ApiKeysController < BaseController
      # spec 14.5, A17.1
      def index
        keys = current_user.api_keys
        render json: { api_keys: keys.map { |k| ApiKeySerializer.new(k).to_h } }
      end

      def create
        key = current_user.api_keys.build(api_key_params)
        if key.save
          render json: {
            api_key: ApiKeySerializer.new(key).to_h,
            token: key.raw_token  # Only shown once at creation
          }, status: :created
        else
          render json: ErrorSerializer.serialize(key.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def destroy
        key = current_user.api_keys.find_by!(key: params[:id])
        key.destroy!
        head :no_content
      end

      private

      def api_key_params
        permitted = params.permit(:name, scopes: [])
        # Drop unknown scope strings rather than 422-ing; ApiKey also validates.
        permitted[:scopes] = Array(permitted[:scopes]) & ApiKey::SCOPES if permitted.key?(:scopes)
        permitted
      end
    end
  end
end
