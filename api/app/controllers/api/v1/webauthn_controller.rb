module Api
  module V1
    class WebauthnController < BaseController
      skip_before_action :authenticate_user!, only: [:authenticate_options, :authenticate]

      # A session this young has just proved who it is; an older one has to show
      # the password again before it may add a way in.
      REAUTH_WINDOW = 10.minutes

      # spec 2.1.5, A1.9 — Registration (requires auth). A new passkey is a
      # permanent way into the account, so a session token alone — which may be
      # stolen — can't mint one: it takes a fresh sign-in or the password. (The
      # fingerprint prompt is no defence: it verifies whoever holds the device
      # being enrolled, and that would be the thief's.) The fresh-sign-in path
      # is what lets SSO users, who have no password they know, add one.
      def registration_options
        unless recently_signed_in? || current_user.authenticate(params[:password].to_s)
          message = params[:password].present? ? "Invalid password" : "Enter your password to add a passkey"
          return render json: ErrorSerializer.serialize(message, status: 401), status: :unauthorized
        end

        current_user.update!(webauthn_id: WebAuthn.generate_user_id) unless current_user.webauthn_id

        options = WebAuthn::Credential.options_for_create(
          user: {
            id: current_user.webauthn_id,
            name: current_user.username,
            display_name: current_user.username
          },
          exclude: current_user.webauthn_credentials.pluck(:external_id),
          # Discoverable + user-verified: the passkey signs in on its own (no
          # username typed, no TOTP step), so it must itself be two factors.
          authenticator_selection: { resident_key: "required", user_verification: "required" }
        )

        # Bound to the user who passed the check above: the challenge lives in a
        # cookie, so without this it could be redeemed under someone else's token.
        session[:webauthn_registration_challenge] = options.challenge
        session[:webauthn_registration_user] = current_user.id

        render json: options
      end

      def register
        challenge = session.delete(:webauthn_registration_challenge) # single use
        issued_to = session.delete(:webauthn_registration_user)
        return invalid_credential unless challenge && issued_to == current_user.id && credential_param

        webauthn_credential = WebAuthn::Credential.from_create(credential_param)
        webauthn_credential.verify(challenge, user_verification: true)

        # `id` is the base64url credential id — the same form the browser sends
        # back at sign-in and the form `exclude`/`allow` lists must carry.
        credential = current_user.webauthn_credentials.create!(
          external_id: webauthn_credential.id,
          public_key: webauthn_credential.public_key,
          nickname: params[:nickname].presence || "Passkey",
          sign_count: webauthn_credential.sign_count
        )

        render json: WebauthnCredentialSerializer.new(credential).to_h, status: :created
      rescue WebAuthn::Error => e
        render json: ErrorSerializer.serialize(e.message, status: 422), status: :unprocessable_content
      end

      # spec 2.1.5, A1.9 — Authentication (no auth required). No allow-list:
      # passkeys are discoverable, and a per-username list would tell anyone
      # which usernames exist and have one.
      def authenticate_options
        options = WebAuthn::Credential.options_for_get(user_verification: "required")

        session[:webauthn_authentication_challenge] = options.challenge

        render json: options
      end

      def authenticate
        challenge = session.delete(:webauthn_authentication_challenge) # single use
        return invalid_credential unless challenge && credential_param

        webauthn_credential = WebAuthn::Credential.from_get(credential_param)
        stored = WebauthnCredential.find_by!(external_id: webauthn_credential.id)

        webauthn_credential.verify(
          challenge,
          public_key: stored.public_key,
          sign_count: stored.sign_count,
          user_verification: true
        )

        stored.update!(sign_count: webauthn_credential.sign_count)

        # Create session
        api_session = create_session_for(stored.user)
        render json: { token: api_session.raw_token, user: UserSerializer.new(stored.user).to_h }
      rescue WebAuthn::Error => e
        render json: ErrorSerializer.serialize(e.message, status: 422), status: :unprocessable_content
      end

      # List credentials
      def index
        render_credentials
      end

      # PUT auth/webauthn/requirement { required, password } — opt in/out of "a
      # password alone doesn't sign me in". Turning it on is refused without a
      # fallback: one passkey and nothing else means a lost device is a locked
      # account. Turning it off is a security downgrade, so (like disabling TOTP)
      # it needs the password again — a stolen session alone must not do it.
      def requirement
        required = ActiveModel::Type::Boolean.new.cast(params[:required]) == true
        if required && !current_user.passkey_fallback?
          return render json: ErrorSerializer.serialize(
            "Add a second passkey or an authenticator app first, so losing one device can't lock you out.", status: 422
          ), status: :unprocessable_content
        end
        if !required && current_user.passkey_required? && !current_user.authenticate(params[:password])
          return render json: ErrorSerializer.serialize("Invalid password", status: 401), status: :unauthorized
        end

        current_user.update!(passkey_required: required)
        render_credentials
      end

      # Delete credential
      def destroy
        credential = current_user.webauthn_credentials.find_by!(external_id: params[:id])
        if current_user.passkey_required? && !current_user.passkey_fallback?(current_user.webauthn_credentials.count - 1)
          return render json: ErrorSerializer.serialize(
            "Turn off \"Don't allow password-only sign-in\" before removing this passkey.", status: 422
          ), status: :unprocessable_content
        end

        credential.destroy!
        head :no_content
      end

      private

      def recently_signed_in?
        current_session.present? && current_session.created_at > REAUTH_WINDOW.ago
      end

      def render_credentials
        credentials = current_user.webauthn_credentials.map { |c| WebauthnCredentialSerializer.new(c).to_h }
        render json: { credentials: credentials, required: current_user.passkey_required }
      end

      def credential_param
        c = params[:credential]
        c if c.is_a?(ActionController::Parameters) && c[:id].present? && c[:response].is_a?(ActionController::Parameters)
      end

      def invalid_credential
        render json: ErrorSerializer.serialize("Invalid credential data", status: 422), status: :unprocessable_content
      end
    end
  end
end
