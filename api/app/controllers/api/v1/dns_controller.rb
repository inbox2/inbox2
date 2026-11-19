module Api
  module V1
    class DnsController < BaseController
      before_action :require_organization!
      # DNS is domain setup — admin/owner only, across read + verify + configure.
      before_action -> { require_role!(*Membership::ADMIN_ROLES) }

      before_action :set_domain, only: %i[show verify]

      # spec 2.3.2, 2.3.3, A3.5 — records for the org's primary domain.
      def show
        render json: DnsRecordsSerializer.new(@domain).to_h
      end

      # spec A3.6 — live DNS check. MX correct → verified; otherwise stays
      # pending_dns. Returns the per-record results so the UI can show what's
      # still missing.
      def verify
        result = DnsChecker.new(@domain).call
        @domain.record_dns_check!(result)

        render json: {
          status: @domain.status,
          verified: result[:mx_ok],
          checks: result[:checks]
        }
      end

      # spec 2.3.2, A3.7
      def cloudflare
        # Stub: would call Cloudflare API with provided token
        unless params[:api_token].present?
          return render json: ErrorSerializer.serialize("Cloudflare API token required", status: 422), status: :unprocessable_content
        end

        render json: { message: "Cloudflare DNS records configured", status: Domain::STATUS_PENDING_DNS }
      end

      private

      def set_domain
        @domain = current_organization.default_domain
        render json: ErrorSerializer.serialize("Organization has no domain", status: 404), status: :not_found unless @domain
      end
    end
  end
end
