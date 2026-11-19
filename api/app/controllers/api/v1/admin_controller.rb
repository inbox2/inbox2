module Api
  module V1
    # Aggregate stats for the MX admin console (/admin). Org-scoped; the web
    # console fans this out across the user's domains and sums client-side.
    class AdminController < BaseController
      before_action :require_organization!

      # GET /api/v1/orgs/:org_id/admin/overview[?domain=dom_…]
      # With ?domain=, the stats are narrowed to that one domain's slice of the
      # pool (per-domain console cards); without it, the whole org.
      def overview
        require_role!(*Membership::ADMIN_ROLES)

        domain = params[:domain].present? ? current_organization.domains.find_by(key: params[:domain]) : nil
        render json: { overview: AdminOverview.new(current_organization, domain: domain).call }
      end
    end
  end
end
