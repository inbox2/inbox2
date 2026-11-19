module Api
  module V1
    module EspAdmin
      # Send-only domains: verified by DNS, never hosted.
      class DomainsController < BaseController
        before_action :set_domain, only: %i[destroy verify]

        def index
          domains = current_organization.esp_domains.order(:name)
          render json: { domains: domains.map { |d| EspDomainSerializer.new(d).to_h } }
        end

        def create
          domain = current_organization.esp_domains.new(name: params[:domain].to_s)
          if domain.save
            render json: { domain: EspDomainSerializer.new(domain).to_h }, status: :created
          else
            render json: ErrorSerializer.serialize(domain.errors.full_messages, status: 422), status: :unprocessable_content
          end
        end

        def verify
          @domain.check_dns!
          render json: { domain: EspDomainSerializer.new(@domain).to_h }
        end

        def destroy
          @domain.destroy!
          head :no_content
        end

        private

        def set_domain
          @domain = current_organization.esp_domains.find_by!(key: params[:id])
        end
      end
    end
  end
end
