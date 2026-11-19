module Api
  module V1
    # Stateless OAuth proxy base — keeps the provider client_id/secret on the
    # server. Clients send auth codes and refresh tokens here; the API exchanges
    # them with the provider and returns the resulting tokens verbatim. Nothing
    # is stored.
    #
    # Subclasses supply the provider specifics via the protected hooks below
    # (provider_name, authorize_url, token_url, scopes, client_id, client_secret)
    # and may override authorize_query / exchange_form / refresh_form to add
    # provider-specific params.
    class OauthProxyController < BaseController
      skip_before_action :authenticate_user!

      ALLOWED_REDIRECT_PATTERNS = [
        %r{\Ahttp://localhost:\d+/oauth-callback\z},
        %r{\Ahttp://127\.0\.0\.1:\d+/oauth-callback\z}
      ].freeze

      # GET .../authorize — Params: redirect_uri (required), state (optional),
      # login_hint (optional: the account being re-authenticated — both Google
      # and Microsoft preselect/prefill that account in the consent screen, so
      # a reconnect can't silently re-auth the wrong mailbox), code_challenge +
      # code_challenge_method (optional: PKCE, RFC 7636 — forwarded to the provider
      # so a native client's intercepted code can't be redeemed without the
      # verifier; left off for clients that don't use PKCE).
      # Returns: { auth_url, state }
      def authorize
        redirect_uri = params.require(:redirect_uri)
        return unless validate_redirect_uri!(redirect_uri)

        state = params[:state].presence || SecureRandom.hex(32)
        query = authorize_query(redirect_uri, state)
        query[:login_hint] = params[:login_hint] if params[:login_hint].present?
        if params[:code_challenge].present?
          query[:code_challenge] = params[:code_challenge]
          query[:code_challenge_method] = params[:code_challenge_method].presence || "S256"
        end
        render json: { auth_url: "#{authorize_url}?#{query.to_query}", state: state }
      end

      # POST .../token — Params: code (required), redirect_uri (required),
      # code_verifier (optional: the PKCE verifier matching the challenge sent at
      # authorize — forwarded so the provider can complete the binding).
      def exchange
        code = params.require(:code)
        redirect_uri = params.require(:redirect_uri)
        return unless validate_redirect_uri!(redirect_uri)

        form = exchange_form(code, redirect_uri)
        form[:code_verifier] = params[:code_verifier] if params[:code_verifier].present?
        response = token_request(form)
        render_token_response(response, "token exchange")
      end

      # POST .../refresh — Params: refresh_token (required)
      def refresh
        refresh_token = params.require(:refresh_token)
        response = token_request(refresh_form(refresh_token))
        render_token_response(response, "token refresh")
      end

      private

      # ── provider hook (subclasses supply the OauthProvider slug) ────────────
      def provider = raise(NotImplementedError)

      def provider_name = OauthProvider.label(provider)
      def authorize_url = OauthProvider.authorize_url(provider)
      def token_url = OauthProvider.token_url(provider)
      def scopes = OauthProvider.scopes(provider)
      def client_id = OauthProvider.client_id(provider)
      def client_secret = OauthProvider.client_secret(provider)

      # ── overridable request shapes ──────────────────────────────────────────
      def authorize_query(redirect_uri, state)
        {
          client_id: client_id,
          redirect_uri: redirect_uri,
          response_type: "code",
          scope: scopes,
          prompt: "consent",
          state: state
        }.merge(OauthProvider.authorize_extra(provider))
      end

      def exchange_form(code, redirect_uri)
        {
          code: code,
          client_id: client_id,
          client_secret: client_secret,
          redirect_uri: redirect_uri,
          grant_type: "authorization_code"
        }.merge(OauthProvider.token_extra(provider))
      end

      def refresh_form(refresh_token)
        {
          refresh_token: refresh_token,
          client_id: client_id,
          client_secret: client_secret,
          grant_type: "refresh_token"
        }.merge(OauthProvider.token_extra(provider))
      end

      # ── shared plumbing ─────────────────────────────────────────────────────
      def render_token_response(response, action)
        if response.is_a?(Net::HTTPSuccess)
          render json: JSON.parse(response.body)
        else
          # Surface the provider's upstream reason (e.g. invalid_grant) in the
          # server log — it's otherwise invisible since Rails doesn't log
          # response bodies.
          Rails.logger.warn("[oauth-proxy] #{provider_name} #{action} failed: " \
                            "HTTP #{response.code} #{response.body}")
          # Pass a provider 4xx through as-is: a rejected grant (invalid_grant =
          # revoked/expired refresh token) is a CLIENT problem the sync engine
          # must see to flag the account needs_reauth. Wrapping everything in a
          # 502 made a dead token indistinguishable from a proxy outage, so
          # clients treated it as transient and never prompted for re-auth.
          status = response.code.to_i.between?(400, 499) ? response.code.to_i : 502
          render json: ErrorSerializer.serialize("#{provider_name} #{action} failed: #{response.body}", status: status),
                 status: status
        end
      end

      def validate_redirect_uri!(uri)
        unless ALLOWED_REDIRECT_PATTERNS.any? { |pattern| pattern.match?(uri) }
          render json: ErrorSerializer.serialize("Invalid redirect_uri", status: 422),
                 status: :unprocessable_content
          return false
        end
        true
      end

      def token_request(form_data) = OauthProvider.post_form(token_url, form_data)
    end
  end
end
