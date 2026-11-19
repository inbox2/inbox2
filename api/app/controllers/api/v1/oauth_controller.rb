module Api
  module V1
    # spec 2.1.6, A1.10 — Social/SSO login (Google, Microsoft)
    class OauthController < BaseController
      skip_before_action :authenticate_user!, only: [:callback]

      # Returns available OAuth providers
      def providers
        render json: {
          providers: OauthIdentity::PROVIDERS.map do |p|
            { name: p, auth_url: "/auth/#{provider_route(p)}" }
          end
        }
      end

      # API-driven OAuth callback. The frontend completes the provider's OAuth
      # flow and posts the resulting access_token; we VERIFY that token with the
      # provider and derive identity (uid/email) from the provider's response.
      # Client-supplied uid/email are ignored — trusting them was an auth bypass
      # (anyone could mint a session for a known uid).
      def callback
        provider = params[:provider]
        unless OauthIdentity::PROVIDERS.include?(provider)
          return render json: ErrorSerializer.serialize("Unknown provider", status: 422), status: :unprocessable_content
        end

        access_token = params[:access_token]
        if access_token.blank?
          return render json: ErrorSerializer.serialize("Missing access token", status: 422), status: :unprocessable_content
        end

        verified = OauthVerifier.verify(provider, access_token)
        unless verified
          return render json: ErrorSerializer.serialize("Could not verify identity with provider", status: 401), status: :unauthorized
        end

        uid = verified.uid
        email = verified.email
        name = verified.name

        identity = OauthIdentity.find_by(provider: provider, uid: uid)

        if identity
          # Existing user — log in
          user = identity.user
          identity.update!(email: email, name: name)
        else
          # Always create a new user — never auto-link by username to prevent account takeover
          user = create_oauth_user(email, name)
          identity = user.oauth_identities.create!(
            provider: provider,
            uid: uid,
            email: email,
            name: name
          )
        end

        identity.store_tokens!(
          access_token: access_token,
          refresh_token: params[:refresh_token],
          expires_at: params[:expires_at]
        )

        session = create_session_for(user)
        render json: {
          token: session.raw_token,
          user: UserSerializer.new(user).to_h,
          new_account: identity.previously_new_record?
        }
      end

      # List linked identities for current user
      def index
        identities = current_user.oauth_identities.map { |id| OauthIdentitySerializer.new(id).to_h }
        render json: { identities: identities }
      end

      # Unlink an identity
      def destroy
        identity = current_user.oauth_identities.find_by!(provider: params[:provider])

        if current_user.oauth_identities.count <= 1 && !current_user.password_digest.present?
          return render json: ErrorSerializer.serialize("Cannot unlink last identity without a password set", status: 422),
            status: :unprocessable_content
        end

        identity.destroy!
        head :no_content
      end

      private

      def provider_route(provider)
        case provider
        when OauthIdentity::PROVIDER_GOOGLE then "google_oauth2"
        when OauthIdentity::PROVIDER_MICROSOFT then "microsoft_graph"
        else provider
        end
      end

      def create_oauth_user(email, name)
        # Derive a valid username base from the email local-part; fall back to a
        # generic base when the provider withheld a (verified) email. Strip chars
        # the username validation forbids, then de-collide.
        base = email.to_s.split("@").first.to_s.gsub(/[^a-zA-Z0-9_\-]/, "")
        base = "user" if base.length < 3
        username = base
        username = "#{base}_#{SecureRandom.hex(3)}" while User.exists?(username: username)

        User.create!(
          username: username,
          password: SecureRandom.hex(24)
        )
      end
    end
  end
end
