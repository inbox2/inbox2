module Api
  module V1
    # Google OAuth proxy. Endpoints + scopes come from OauthProvider; the shared
    # flow lives in OauthProxyController.
    class GoogleOauthProxyController < OauthProxyController
      private

      def provider = OauthProvider::GOOGLE
    end
  end
end
