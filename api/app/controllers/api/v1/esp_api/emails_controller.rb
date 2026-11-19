module Api
  module V1
    module EspApi
      # The ESP's public surface (docs/ESP.md): an application sends mail and
      # reads back what happened, with an org sending key (isk_…). No user, no
      # session; the key names the org.
      class EmailsController < ApplicationController
        include Paginatable

        before_action :authenticate_key!
        rescue_from(::Esp::Refused) { |e| render json: ErrorSerializer.serialize(e.message, status: e.status), status: e.status }

        # POST /api/v1/esp/emails
        def create
          message, created = ::Esp::Send.new(@esp_key, send_params,
            idempotency_key: request.headers["Idempotency-Key"]).call
          render json: { email: EspEmailSerializer.new(message).to_h }, status: created ? :accepted : :ok
        end

        # GET /api/v1/esp/emails
        def index
          scope = organization.esp_messages.includes(:deliveries).order(id: :desc)
          scope = scope.where(tag: params[:tag]) if params[:tag].present?
          records, meta = paginate(scope, default_per_page: 25, max_per_page: 100)
          render json: { emails: records.without_body.map { |m| EspEmailSerializer.new(m).to_h }, meta: meta }
        end

        # GET /api/v1/esp/emails/:id
        def show
          message = organization.esp_messages.without_body.find_by!(key: params[:id])
          render json: { email: EspEmailSerializer.new(message, params: { events: true }).to_h }
        end

        private

        def organization = @esp_key.organization

        def authenticate_key!
          @esp_key = ::Esp::Key.authenticate(bearer_token)
          render json: ErrorSerializer.serialize("Unauthorized", status: 401), status: :unauthorized unless @esp_key
        end

        def send_params
          params.permit(:from, :reply_to, :subject, :text, :html, :tag,
            to: [], cc: [], bcc: [], metadata: {}, headers: {},
            attachments: %i[filename content_type content]).tap do |p|
            # A single address may be given as a string.
            %i[to cc bcc].each { |f| p[f] = [params[f]] if params[f].is_a?(String) }
          end
        end
      end
    end
  end
end
