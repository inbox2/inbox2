module Api
  module V1
    module EspAdmin
      class KeysController < BaseController
        def index
          keys = current_organization.esp_keys.active.order(:id)
          render json: { keys: keys.map { |k| EspKeySerializer.new(k).to_h } }
        end

        # The token is shown once, here, and never again.
        def create
          key = current_organization.esp_keys.new(name: params[:name].to_s.strip, created_by: current_user)
          if key.save
            render json: { key: EspKeySerializer.new(key).to_h, token: key.raw_token }, status: :created
          else
            render json: ErrorSerializer.serialize(key.errors.full_messages, status: 422), status: :unprocessable_content
          end
        end

        # Revoked, not deleted: the send log still names the key.
        def destroy
          current_organization.esp_keys.active.find_by!(key: params[:id]).update!(revoked_at: Time.current)
          head :no_content
        end
      end
    end
  end
end
