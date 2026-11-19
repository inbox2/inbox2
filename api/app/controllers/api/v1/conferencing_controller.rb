module Api
  module V1
    # Per-member Google/Microsoft conferencing connections (docs/Calendar.md):
    # the narrow OAuth grant that lets an accepted meeting request carry a
    # generated Meet/Teams link. Piggybacks on the OauthProvider registry with
    # conferencing-only scopes — this grant can create meetings and identify
    # the account, nothing else.
    class ConferencingController < BaseController
      # The provider's redirect arrives with no inbox2 session; the signed,
      # expiring `state` (minted in #connect for a live membership) is the
      # authorization.
      skip_before_action :authenticate_user!, only: :callback
      skip_before_action :enforce_api_key_scope!, only: :callback
      before_action :require_organization!, except: :callback

      STATE_TTL = 15.minutes

      # GET /api/v1/orgs/:org_id/conferencing
      def index
        connections = ConferencingConnection.where(membership: current_active_membership!)
        render json: { connections: connections.map { |c| ConferencingConnectionSerializer.new(c).to_h } }
      end

      # POST /api/v1/orgs/:org_id/conferencing/:provider/connect
      def connect
        provider = provider_param
        return unless provider

        state = self.class.verifier.generate(
          { "m" => current_active_membership!.key, "o" => current_organization.slug, "n" => SecureRandom.hex(12) },
          expires_in: STATE_TTL
        )
        render json: {
          authorize_url: OauthProvider.authorize_uri(
            provider,
            redirect_uri: callback_uri(provider),
            state: state,
            scope: ConferencingConnection::SCOPES[provider]
          )
        }
      end

      # GET /api/v1/conferencing/:provider/callback — the provider's redirect.
      def callback
        provider = params[:provider].to_s
        data = self.class.verifier.verified(params[:state])
        return redirect_to fallback_web_url, allow_other_host: true if data.nil? || !state_unused?(data["n"])

        org_slug = data["o"]
        return redirect_to settings_url(org_slug, "error"), allow_other_host: true if params[:error].present? || !OauthProvider.known?(provider)

        membership = Membership.find_by(key: data["m"], status: Membership::STATUS_ACTIVE)
        return redirect_to settings_url(org_slug, "error"), allow_other_host: true unless membership

        tokens = OauthProvider.exchange_code(
          provider, params.require(:code), callback_uri(provider),
          scope: ConferencingConnection::SCOPES[provider]
        )
        if tokens["refresh_token"].blank?
          Rails.logger.warn("[conferencing] #{provider} returned no refresh token")
          return redirect_to settings_url(org_slug, "error"), allow_other_host: true
        end

        connection = ConferencingConnection.find_or_initialize_by(membership: membership, provider: provider)
        connection.refresh_token = tokens["refresh_token"]
        connection.account_email = OauthProvider.fetch_email(provider, tokens["access_token"])
        connection.save!

        redirect_to settings_url(org_slug, "connected"), allow_other_host: true
      rescue OauthProvider::Error => e
        Rails.logger.warn("[conferencing] #{e.message}")
        org_slug = params[:state].present? ? self.class.verifier.verified(params[:state])&.dig("o") : nil
        redirect_to settings_url(org_slug, "error"), allow_other_host: true
      end

      # DELETE /api/v1/orgs/:org_id/conferencing/:provider
      def destroy
        provider = provider_param
        return unless provider

        ConferencingConnection.find_by!(membership: current_active_membership!, provider: provider).destroy!
        head :no_content
      end

      def self.verifier
        Rails.application.message_verifier(:conferencing)
      end

      private

      def provider_param
        provider = params[:provider].to_s
        unless OauthProvider.known?(provider)
          render json: ErrorSerializer.serialize("Unsupported provider", status: 422), status: :unprocessable_content
          return nil
        end
        provider
      end

      # Must be byte-identical between #connect and #callback — the provider
      # verifies the registered URI and the token exchange replays it.
      def callback_uri(provider)
        "#{request.base_url}/api/v1/conferencing/#{provider}/callback"
      end

      # One callback per state (same claim the Disk importer uses): a replayed
      # provider redirect must not re-run the code exchange / overwrite tokens.
      def state_unused?(nonce)
        nonce.present? && Rails.cache.write("conferencing:state:#{nonce}", true, expires_in: STATE_TTL, unless_exist: true)
      end

      def settings_url(org_slug, status)
        base = fallback_web_url
        org_slug.present? ? "#{base}/#{org_slug}/settings?section=scheduling&conferencing=#{status}" : base
      end

      def fallback_web_url
        ENV.fetch("WEB_APP_URL", "https://app.inbox2.com").chomp("/")
      end
    end
  end
end
