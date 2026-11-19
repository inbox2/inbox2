module Api
  module V1
    class AuthController < BaseController
      skip_before_action :authenticate_user!, only: %i[signup login confirm_email reset_password_request reset_password]

      # POST /api/v1/auth/signup — spec 2.1.1, A1.1
      def signup
        # Invite-only gate (pre-launch). When INVITE_ENABLED, a valid outstanding
        # waitlist invite token is required; the account's email/display name are
        # taken from the waitlist row. Flipped off for the open prod rollout.
        waitlist = nil
        if WaitlistSignup.invite_only?
          waitlist = WaitlistSignup.find_redeemable_by_token(params[:invite_token])
          unless waitlist
            return render json: ErrorSerializer.serialize("Signups are invite-only", status: 422), status: :unprocessable_content
          end
        end

        attrs = signup_params.except(:invite_token)
        typed_email = nil
        if waitlist
          attrs[:billing_email] = waitlist.email # the invite reached it, so it counts as confirmed
          attrs[:display_name] = waitlist.name if attrs[:display_name].blank?
        else
          typed_email = attrs.delete(:billing_email).to_s.strip.downcase.presence
          if typed_email && !typed_email.match?(URI::MailTo::EMAIL_REGEXP)
            return render json: ErrorSerializer.serialize("Enter a valid email address", status: 422), status: :unprocessable_content
          end
        end

        user = User.new(attrs)

        if user.save
          waitlist&.mark_registered!(user)
          if typed_email
            BillingEmailMailerService.send_confirmation(user, typed_email, user.begin_billing_email_change!(typed_email))
          end
          session = create_session_for(user)
          render json: {
            user: UserSerializer.new(user).to_h,
            token: session.raw_token
          }, status: :created
        else
          render json: ErrorSerializer.serialize(user.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # POST /api/v1/auth/confirm-email { token } — the link mailed to a new contact address.
      def confirm_email
        user = User.find_by_billing_email_token(params[:token])
        unless user
          return render json: ErrorSerializer.serialize("This link has expired. Ask for a new one.", status: 422), status: :unprocessable_content
        end

        user.confirm_billing_email!
        render json: { confirmed: true }
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        render json: ErrorSerializer.serialize("Another account uses this address.", status: 422), status: :unprocessable_content
      end

      # POST /api/v1/auth/login — spec 2.1.3, A1.2
      def login
        user = User.find_by(username: params[:username])

        unless user&.authenticate(params[:password])
          return render json: ErrorSerializer.serialize("Invalid username or password", status: 401), status: :unauthorized
        end

        # The password is right; now the second step. A TOTP code, when sent, settles
        # it. Otherwise an account that requires a passkey is told to present one —
        # the client then runs the ordinary passkey sign-in (webauthn#authenticate),
        # which is a complete login on its own. `requires_2fa` rides along so a
        # client that can't do WebAuthn (the mobile apps) falls back to the code.
        if user.totp_enabled? && params[:totp_code].present?
          unless user.verify_totp(params[:totp_code])
            return render json: ErrorSerializer.serialize("Invalid 2FA code", status: 401), status: :unauthorized
          end
        elsif user.passkey_required?
          return render json: { requires_passkey: true, requires_2fa: user.totp_enabled?, user_id: user.key }
        elsif user.totp_enabled?
          return render json: { requires_2fa: true, user_id: user.key }
        end

        session = create_session_for(user)
        render json: {
          user: UserSerializer.new(user).to_h,
          token: session.raw_token
        }
      end

      # POST /api/v1/auth/logout — spec 2.1.3, A1.3
      def logout
        token = bearer_token.presence || cookies[SESSION_COOKIE].presence
        Session.find_by_token(token)&.destroy
        clear_session_cookie
        head :no_content
      end

      # POST /api/v1/auth/password/reset-request — spec 2.1.3, A1.4
      def reset_password_request
        user = User.find_by(billing_email: params[:email])
        PasswordResetService.call(user) if user
        # Always return accepted to prevent email enumeration
        head :accepted
      end

      # POST /api/v1/auth/password/reset — spec 2.1.3, A1.5
      def reset_password
        user = User.find_by(reset_token: params[:token])

        if user.nil? || !user.reset_token_valid?
          return render json: ErrorSerializer.serialize("Invalid or expired reset token", status: 422), status: :unprocessable_content
        end

        if user.update(password: params[:password])
          user.clear_reset_token!
          user.sessions.destroy_all
          render json: { message: "Password reset successfully" }
        else
          render json: ErrorSerializer.serialize(user.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # GET /api/v1/auth/sessions — spec 2.1.4, A1.6
      def sessions
        sessions = current_user.sessions.active.order(last_active_at: :desc)
        render json: { sessions: sessions.map { |s| SessionSerializer.new(s).to_h } }
      end

      # DELETE /api/v1/auth/sessions — spec 2.1.4, A1.7
      def destroy_all_sessions
        token = bearer_token.presence || cookies[SESSION_COOKIE].presence
        digest = Digest::SHA256.hexdigest(token.to_s)
        current_user.sessions.where.not(token_digest: digest).destroy_all
        head :no_content
      end

      private

      def signup_params
        params.permit(:username, :password, :password_confirmation, :display_name, :billing_email, :invite_token)
      end
    end
  end
end
