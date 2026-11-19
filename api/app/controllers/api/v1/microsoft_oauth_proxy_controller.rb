module Api
  module V1
    # Microsoft OAuth proxy (identity platform, multi-tenant + personal accounts).
    # Endpoints + scopes come from OauthProvider; the shared flow lives in
    # OauthProxyController.
    class MicrosoftOauthProxyController < OauthProxyController
      private

      def provider = OauthProvider::MICROSOFT
    end
  end
end
