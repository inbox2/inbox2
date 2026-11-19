module Api
  module V1
    # The "link this device to your inbox2 account" flow (loopback + PKCE),
    # OAuth-style. Two steps:
    #
    #   authorize — called by the WEB approval page (session/cookie authed). Mints
    #               a pending, PKCE-bound code for current_user and returns it so
    #               the browser can 302 back to the client's loopback listener.
    #   token     — called by the NATIVE CLIENT (public; the client proves itself
    #               with the PKCE verifier, no session). Redeems the code for a
    #               long-lived, device-scoped ink_ ApiKey.
    #
    # See docs/Device-Link.md.
    class DeviceLinkController < BaseController
      # The token exchange is unauthenticated by design — the holder of the PKCE
      # verifier matching the approved challenge IS the authorized client.
      skip_before_action :authenticate_user!, only: :token
      skip_before_action :enforce_api_key_scope!, only: :token

      # POST /api/v1/auth/device-link/authorize
      def authorize
        req = current_user.device_link_requests.build(authorize_params)

        if req.save
          render json: { code: req.raw_code, redirect_uri: req.redirect_uri }, status: :created
        else
          render json: ErrorSerializer.serialize(req.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # POST /api/v1/auth/device-link/token
      def token
        req = DeviceLinkRequest.authenticate(params[:code])

        unless req && req.verifier_matches?(params[:code_verifier]) && req.redirect_uri == params[:redirect_uri]
          return render json: ErrorSerializer.serialize("Invalid or expired device link code", status: 400),
            status: :bad_request
        end

        key = nil
        DeviceLinkRequest.transaction do
          key = req.user.api_keys.create!(
            name: req.device_name,
            scopes: ApiKey::SCOPES,
            device_platform: req.platform
          )
          req.consume!
        end

        render json: {
          token: key.raw_token, # shown once
          api_key: ApiKeySerializer.new(key).to_h,
          user: UserSerializer.new(req.user).to_h
        }, status: :created
      end

      private

      def authorize_params
        params.permit(:code_challenge, :code_challenge_method, :redirect_uri, :device_name, :platform)
      end
    end
  end
end
