module Api
  module V1
    class OrganizationsController < BaseController
      include ImageAssets

      before_action :require_organization!, only: %i[show update upload_icon upload_logo destroy]
      skip_before_action :authenticate_user!, only: :brand

      # POST /api/v1/orgs — spec 2.3.1, A3.1
      def create
        domain_name = params[:domain].to_s.downcase.strip
        if domain_name.blank?
          return render json: ErrorSerializer.serialize("domain is required", status: 422), status: :unprocessable_content
        end
        if Domain.exists?(name: domain_name)
          return render json: ErrorSerializer.serialize("Domain already in use", status: 422), status: :unprocessable_content
        end

        org = Organization.provision!(owner: current_user, domain_name: domain_name, **org_params.to_h.symbolize_keys)
        # Pull the domain's brand icon in the background (best-effort).
        FetchFaviconJob.perform_later(org.id)
        render json: { organization: OrganizationSerializer.new(org).to_h }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: ErrorSerializer.serialize(e.record.errors.full_messages, status: 422), status: :unprocessable_content
      end

      # GET /api/v1/orgs/:org_id — spec A3.2
      def show
        render json: { organization: OrganizationSerializer.new(current_organization, params: { membership: current_membership }).to_h }
      end

      # PATCH /api/v1/orgs/:org_id — spec A3.3
      def update
        require_role!(*Membership::ADMIN_ROLES)

        if current_organization.update(org_update_params)
          render json: { organization: OrganizationSerializer.new(current_organization).to_h }
        else
          render json: ErrorSerializer.serialize(current_organization.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # DELETE /api/v1/orgs/:org_id — remove a connected domain (owner only).
      # Cascades to conversations/messages/spaces/members via dependent: :destroy.
      def destroy
        require_role!(Membership::ROLE_OWNER)

        current_organization.destroy!
        head :no_content
      end

      # Upload org square icon (shown in the workspace tab) to S3 and set icon_url
      def upload_icon
        store_brand_image!(:icon_url, "Icon")
      end

      # Upload org company logo (wide brand logo, shown in admin + login) and set logo_url
      def upload_logo
        store_brand_image!(:logo_url, "Logo")
      end

      # GET /api/v1/orgs/:org_id/brand/:kind — public. Streams the org's stored
      # icon/logo so brand assets load in plain <img> tags (no auth). Streaming
      # (vs a presigned redirect) keeps object storage fully private/internal —
      # the signed URL would otherwise point at the in-cluster S3 host the
      # browser can't reach. Assets are small and heavily cached.
      def brand
        org = Organization.find_by(key: params[:org_id])
        return head :not_found unless org

        storage_key = params[:kind] == "logo" ? org.logo_url : org.resolved_icon_key
        return head :not_found if storage_key.blank?

        bytes, content_type = storage_service.download_with_type(storage_key)
        expires_in 1.day, public: true
        send_image_asset(bytes, content_type)
      rescue Aws::S3::Errors::NoSuchKey
        head :not_found
      rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError, KeyError => e
        Rails.logger.error("[OrganizationsController] brand fetch failed: #{e.class}: #{e.message}")
        head :service_unavailable
      end

      # POST /api/v1/orgs/:org_id/icon/fetch — (re)pull the domain's favicon /
      # OpenGraph image, store it, and set icon_url.
      def fetch_icon
        require_role!(*Membership::ADMIN_ROLES)

        result = FaviconFetcher.new(current_organization.default_domain&.name).call
        unless result
          return render json: ErrorSerializer.serialize(
            "Couldn't find an icon for #{current_organization.default_domain&.name}", status: 422
          ), status: :unprocessable_content
        end

        OrgIcon.store!(current_organization, result)
        render json: { organization: OrganizationSerializer.new(current_organization).to_h }
      rescue Aws::Errors::ServiceError => e
        Rails.logger.error("[OrganizationsController] Favicon store failed: #{e.message}")
        render json: ErrorSerializer.serialize("Storage service unavailable", status: 503), status: :service_unavailable
      end

      # spec 2.4.2, A3.11
      def test_email
        require_organization!
        return if performed?

        render json: {
          message: "Test email initiated to #{current_organization.default_domain&.name}",
          status: Conversation::STATUS_PENDING
        }
      end

      # spec 2.4.1, A3.12
      def onboarding
        require_organization!
        return if performed?

        render json: OrganizationOnboardingSerializer.new(current_organization).to_h
      end

      private

      def org_params
        params.permit(:name, :timezone, :language)
      end

      def org_update_params
        # icon_url / logo_url are set only via the upload/fetch endpoints (they
        # hold an internal storage key, not a client-supplied value).
        params.permit(:name, :timezone, :language, :view_creation_policy, :activity_tracking_enabled, :mail_clients_enabled)
      end

      # Shared upload path for the two brand images (square icon + company logo):
      # validate → store on S3 → set the given column to a long-lived presigned URL.
      def store_brand_image!(attr, label)
        require_role!(*Membership::ADMIN_ROLES)

        file = params[:file]
        # Trust the sniffed type, never the client-supplied Content-Type.
        content_type = validate_image_upload!(file, label: label)
        return unless content_type

        storage_key = storage_service.upload(
          file.read,
          filename: file.original_filename,
          content_type: content_type,
          organization_key: current_organization.key
        )

        # Store the object key (not a presigned URL): SigV4 presigned URLs cap at
        # 7 days, so a "permanent" URL is impossible. The brand endpoint re-signs
        # short-lived on each read instead.
        current_organization.update!(attr => storage_key)

        render json: { organization: OrganizationSerializer.new(current_organization).to_h }
      rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError, KeyError => e
        # Storage unreachable (Garage/S3 down) or misconfigured (missing creds).
        # Return a clean 503 rather than letting it surface as an opaque 500.
        Rails.logger.error("[OrganizationsController] #{label} upload failed: #{e.class}: #{e.message}")
        render json: ErrorSerializer.serialize("Storage service unavailable — try again shortly", status: 503), status: :service_unavailable
      end

      def storage_service
        @storage_service ||= S3StorageService.new
      end
    end
  end
end
