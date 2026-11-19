module Api
  module V1
    class AccountsController < BaseController
      include ImageAssets

      # The avatar stream loads in plain <img> tags, which can't carry the
      # bearer token, so the route itself skips session auth. Access is instead
      # gated by a signed, expiring capability token in the URL (see #avatar /
      # AvatarToken) that is only ever minted for an authenticated co-member.
      skip_before_action :authenticate_user!, only: :avatar

      # GET /api/v1/account — spec 2.2.2, A2.1
      def show
        # Preload the plan override + subscription's plan so OrganizationSerializer's
        # `plan` summary doesn't N+1 across every org in the list (effective_plan =
        # plan || subscription.plan || Plan.free).
        orgs = current_user.accessible_organizations.includes(:memberships, :domains, :plan, subscription: :plan)
        # The current user's membership per org → their primary mailbox address
        # (across the org's domains) + the role that drives admin-only UI gating.
        memberships = current_user.memberships.includes(mailboxes: :domain).index_by(&:organization_id)
        first_org = orgs.first
        render json: {
          account: UserSerializer.new(current_user).to_h,
          organizations: orgs.map { |o|
            OrganizationSerializer.new(o, params: { membership: memberships[o.id] }).to_h.merge(
              mailbox: memberships[o.id]&.primary_email_address,
              role: memberships[o.id]&.role,
              # Every address they may send as here (Membership#from_addresses),
              # so the clients' From pickers offer exactly what the server allows.
              from_addresses: memberships[o.id]&.from_addresses || [],
              drive_letter: memberships[o.id]&.drive_letter
            )
          },
          current_org_id: first_org&.key,
          current_org_slug: first_org&.slug
        }
      end

      # PATCH /api/v1/account — spec 2.2.2, A2.2
      def update
        if current_user.update(account_params)
          render json: { account: UserSerializer.new(current_user).to_h }
        else
          render json: ErrorSerializer.serialize(current_user.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # PUT /api/v1/account/billing-email — spec 2.1.8, A2.3
      def update_billing_email
        email = params[:billing_email].to_s.strip.downcase.presence
        unless email.nil? || email.match?(URI::MailTo::EMAIL_REGEXP)
          return render json: ErrorSerializer.serialize("Enter a valid email address", status: 422), status: :unprocessable_content
        end

        warnings = []

        # Warn if Inbox2-hosted domain (any domain across the user's orgs)
        domain = email&.split("@")&.last&.downcase
        if domain.present? && Domain.where(organization_id: current_user.accessible_organizations.select(:id), name: domain).exists?
          warnings << "This email is on a domain hosted by Inbox2. Use an external address to avoid billing notification issues."
        end

        # A new address needs its owner's click (48.21). Clearing it, or re-entering the
        # confirmed one, needs no proof and drops any change still waiting.
        if email && email != current_user.billing_email
          BillingEmailMailerService.send_confirmation(current_user, email, current_user.begin_billing_email_change!(email))
        else
          current_user.update!(billing_email: email, pending_billing_email: nil, billing_email_token_digest: nil,
                               billing_email_token_sent_at: nil)
        end
        render json: { account: UserSerializer.new(current_user).to_h, warnings: warnings }
      end

      # PUT /api/v1/account/password — change the signed-in user's password.
      # Requires re-auth with the current password (mirrors TotpController's gate)
      # so a hijacked session can't silently rotate the password.
      def update_password
        unless current_user.authenticate(params[:current_password].to_s)
          return render json: ErrorSerializer.serialize("Current password is incorrect", status: 422), status: :unprocessable_content
        end

        if current_user.update(password: params[:password])
          head :no_content
        else
          render json: ErrorSerializer.serialize(current_user.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # POST /api/v1/account/avatar — upload a profile picture to S3 and store
      # its object key. Mirrors OrganizationsController#upload_icon.
      def upload_avatar
        file = params[:file]
        # Trust the sniffed type, never the client-supplied Content-Type.
        content_type = validate_image_upload!(file, label: "Avatar")
        return unless content_type

        # Store the object key (not a presigned URL): SigV4 presigned URLs cap at
        # 7 days, so the avatar stream re-signs short-lived on each read instead.
        storage_key = storage_service.upload(
          file.read,
          filename: file.original_filename,
          content_type: content_type,
          organization_key: "users/#{current_user.key}"
        )
        current_user.update!(avatar_url: storage_key)

        render json: { account: UserSerializer.new(current_user).to_h }
      rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError, KeyError => e
        Rails.logger.error("[AccountsController] Avatar upload failed: #{e.class}: #{e.message}")
        render json: ErrorSerializer.serialize("Storage service unavailable — try again shortly", status: 503), status: :service_unavailable
      end

      # GET /api/v1/account/avatar/:token — streams a user's stored avatar so it
      # loads in plain <img> tags. The signed token (minted only while
      # serializing a user to an authenticated co-member) replaces a bearer the
      # <img> request can't send, and makes the endpoint non-enumerable: a raw
      # or guessed usr_ key no longer resolves.
      def avatar
        user_key = AvatarToken.user_key(params[:token])
        return head :not_found unless user_key

        user = User.find_by(key: user_key)
        return head :not_found unless user

        storage_key = user.avatar_url
        return head :not_found if storage_key.blank? || storage_key.start_with?("http")

        bytes, content_type = storage_service.download_with_type(storage_key)
        expires_in 1.day, public: true
        send_image_asset(bytes, content_type)
      rescue Aws::S3::Errors::NoSuchKey
        head :not_found
      rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError, KeyError => e
        Rails.logger.error("[AccountsController] avatar fetch failed: #{e.class}: #{e.message}")
        head :service_unavailable
      end

      private

      def account_params
        permitted = params.permit(
          :display_name, :default_timezone, :default_language,
          :out_of_office_start, :out_of_office_end, :out_of_office_message,
          working_hours: [:start_minute, :end_minute, { days: [] }]
        )
        # An explicit null clears the period ("I'm back"); jsonb wants a plain
        # hash, not ActionController::Parameters.
        permitted[:working_hours] = permitted[:working_hours].to_h if permitted[:working_hours].present?
        permitted
      end

      def storage_service
        @storage_service ||= S3StorageService.new
      end
    end
  end
end
