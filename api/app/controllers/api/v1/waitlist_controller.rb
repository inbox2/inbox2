module Api
  module V1
    # Public, unauthenticated pre-launch interest form. Captures a prospect, bot-
    # gated by Cloudflare Turnstile, deduped on email WITHOUT leaking whether the
    # email already exists (input is validated independently of existence, and the
    # response is always 202). Operators invite from the SaaS surface.
    class WaitlistController < BaseController
      skip_before_action :authenticate_user!, only: %i[create public_config invite_lookup]

      # POST /api/v1/waitlist
      def create
        unless TurnstileVerifier.verify(params[:turnstile_token], remote_ip: request.remote_ip)
          return render json: ErrorSerializer.serialize("Verification failed. Please try again.", status: 422),
            status: :unprocessable_content
        end

        attrs = waitlist_params

        # Validate input shape INDEPENDENT of existence so the response can never
        # differ between a new and an already-registered email (no enumeration).
        errors = []
        errors << "Name can't be blank" if attrs[:name].blank?
        email = attrs[:email].to_s.strip.downcase
        errors << "Email is invalid" unless email.match?(URI::MailTo::EMAIL_REGEXP)
        if errors.any?
          return render json: ErrorSerializer.serialize(errors, status: 422), status: :unprocessable_content
        end

        # Only create + notify for a brand-new email; always return the same 202.
        unless WaitlistSignup.exists?(email: email)
          signup = WaitlistSignup.create(attrs.merge(email: email))
          WaitlistMailerService.notify_signup(signup) if signup.persisted?
        end

        head :accepted
      rescue ActiveRecord::RecordNotUnique
        head :accepted
      end

      # GET /api/v1/waitlist/config — public client config (site key + gate state).
      def public_config
        render json: {
          invite_enabled: WaitlistSignup.invite_only?,
          turnstile_site_key: ENV["TURNSTILE_SITE_KEY"]
        }
      end

      # GET /api/v1/waitlist/invite?token= — prefill for the account-creation screen.
      def invite_lookup
        signup = WaitlistSignup.find_redeemable_by_token(params[:token])
        unless signup
          return render json: ErrorSerializer.serialize("Invalid or expired invite", status: 404), status: :not_found
        end

        render json: { email: signup.email, name: signup.name }
      end

      private

      def waitlist_params
        permitted = params.permit(
          :name, :company, :email, :industry, :industry_note,
          email_services: [:gmail_count, :office365_count, { others: [] }],
          social_accounts: [:whatsapp_count, :meta_count, :messenger_count, { others: [] }]
        )

        {
          name: permitted[:name],
          company: permitted[:company],
          email: permitted[:email],
          industry: permitted[:industry],
          industry_note: permitted[:industry_note].to_s.strip.first(2000).presence,
          email_services: clean_email_services(permitted[:email_services]),
          social_accounts: clean_social_accounts(permitted[:social_accounts])
        }
      end

      # Each named provider is a count (0 = not selected). The web form reveals a
      # +/- counter when its checkbox is ticked.
      def clean_email_services(raw)
        raw ||= {}
        {
          "gmail_count" => count(raw[:gmail_count]),
          "office365_count" => count(raw[:office365_count]),
          "others" => clean_others(raw[:others])
        }
      end

      def clean_social_accounts(raw)
        raw ||= {}
        {
          "whatsapp_count" => count(raw[:whatsapp_count]),
          "meta_count" => count(raw[:meta_count]),
          "messenger_count" => count(raw[:messenger_count]),
          "others" => clean_others(raw[:others])
        }
      end

      def clean_others(list)
        Array(list).map { |o| o.to_s.strip }.reject(&:blank?).first(20)
      end

      def count(value)
        value.to_i.clamp(0, 999)
      end
    end
  end
end
