module Api
  module V1
    # Registered applications (docs/App-OAuth.md) — the console's Applications
    # section. Org-scoped and admin-only, except `icon` which is public because
    # the consent screen renders it with no inbox2 session.
    class OauthAppsController < BaseController
      include ImageAssets

      skip_before_action :authenticate_user!, only: :icon
      skip_before_action :enforce_api_key_scope!, only: :icon
      before_action :require_organization!, except: :icon
      before_action -> { require_role!(*Membership::ADMIN_ROLES) }, except: :icon
      before_action :set_app, only: %i[show update destroy upload_icon]

      def index
        apps = current_organization.oauth_apps.order(:name)
        render json: { oauth_apps: apps.map { |a| OauthAppSerializer.new(a).to_h } }
      end

      def show
        render json: { oauth_app: OauthAppSerializer.new(@app).to_h }
      end

      def create
        app = current_organization.oauth_apps.build(app_params.merge(created_by: current_user))
        if app.save
          render json: { oauth_app: OauthAppSerializer.new(app).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(app.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def update
        if @app.update(app_params)
          render json: { oauth_app: OauthAppSerializer.new(@app).to_h }
        else
          render json: ErrorSerializer.serialize(@app.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def destroy
        @app.destroy!
        head :no_content
      end

      # POST /orgs/:org_id/oauth-apps/:id/icon
      def upload_icon
        file = params[:file]
        content_type = validate_image_upload!(file, label: "Icon")
        return unless content_type

        storage_key = storage_service.upload(
          file.read,
          filename: file.original_filename,
          content_type: content_type,
          organization_key: current_organization.key
        )
        @app.update!(icon_url: storage_key)
        render json: { oauth_app: OauthAppSerializer.new(@app).to_h }
      rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError, KeyError => e
        Rails.logger.error("[OauthAppsController] Icon upload failed: #{e.class}: #{e.message}")
        render json: ErrorSerializer.serialize("Storage service unavailable — try again shortly", status: 503),
               status: :service_unavailable
      end

      # GET /oauth/apps/:app_id/icon — public. The consent screen is shown to a
      # user with no inbox2 account, so its <img> carries no bearer token. Keyed
      # by the app's unguessable public id; an app icon is not a secret.
      def icon
        app = OauthApp.find_by(key: params[:app_id])
        return head :not_found if app&.icon_url.blank?

        bytes, content_type = storage_service.download_with_type(app.icon_url)
        expires_in 1.day, public: true
        send_image_asset(bytes, content_type)
      rescue Aws::S3::Errors::NoSuchKey
        head :not_found
      rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError, KeyError => e
        Rails.logger.error("[OauthAppsController] icon fetch failed: #{e.class}: #{e.message}")
        head :service_unavailable
      end

      private

      def set_app
        @app = current_organization.oauth_apps.find_by!(key: params[:id])
      end

      def app_params
        permitted = params.permit(:name, redirect_uris: [])
        # Accept a newline/comma separated string too — that's how the console
        # textarea and most curl calls send the list.
        if params[:redirect_uris].is_a?(String)
          permitted[:redirect_uris] = params[:redirect_uris].split(/[\s,]+/)
        end
        permitted
      end

      def storage_service
        @storage_service ||= S3StorageService.new
      end
    end
  end
end
