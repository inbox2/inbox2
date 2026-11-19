module Api
  module V1
    class TotpController < BaseController
      # spec 2.1.5, A1.8 — TOTP enrollment + verification

      def enroll
        totp = ROTP::TOTP.new(ROTP::Base32.random, issuer: "Inbox2")
        current_user.update!(totp_secret: totp.secret)

        provisioning_uri = totp.provisioning_uri(current_user.username)
        qr = RQRCode::QRCode.new(provisioning_uri)

        render json: {
          secret: totp.secret,
          provisioning_uri: provisioning_uri,
          qr_svg: qr.as_svg(module_size: 4)
        }
      end

      def verify
        unless current_user.totp_secret.present?
          return render json: ErrorSerializer.serialize("TOTP not enrolled", status: 422), status: :unprocessable_content
        end

        totp = ROTP::TOTP.new(current_user.totp_secret, issuer: "Inbox2")

        verified_at = totp.verify(params[:code], drift_behind: 1, drift_ahead: 1)
        if verified_at
          # Record the consumed timestep so the same enrollment code can't be
          # replayed as the first login factor.
          current_user.update!(totp_enabled: true, totp_last_verified_at: Time.at(verified_at).utc)
          render json: { enabled: true }
        else
          render json: ErrorSerializer.serialize("Invalid code", status: 422), status: :unprocessable_content
        end
      end

      # Disabling 2FA is a security-downgrade, so it requires re-proving both
      # factors — a stolen session token alone must not be able to turn it off.
      def disable
        unless current_user.authenticate(params[:password])
          return render json: ErrorSerializer.serialize("Invalid password", status: 401), status: :unauthorized
        end

        unless current_user.verify_totp(params[:code])
          return render json: ErrorSerializer.serialize("Invalid 2FA code", status: 422), status: :unprocessable_content
        end

        # TOTP may be the fallback the passkey requirement was allowed on (one
        # passkey + TOTP). Don't let it go while that requirement depends on it.
        if current_user.passkey_required? && current_user.webauthn_credentials.count < 2
          return render json: ErrorSerializer.serialize(
            "Add a second passkey, or turn off \"Don't allow password-only sign-in\", before disabling 2FA.", status: 422
          ), status: :unprocessable_content
        end

        current_user.update!(totp_enabled: false, totp_secret: nil, totp_last_verified_at: nil)
        render json: { enabled: false }
      end
    end
  end
end
