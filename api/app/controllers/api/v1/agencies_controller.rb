module Api
  module V1
    class AgenciesController < BaseController
      # spec 13.2.7 — Agency/reseller billing
      def show
        agency = current_user_agency
        render json: { agency: AgencySerializer.new(agency).to_h }
      end

      def create
        # discount_percent is a platform/reseller grant — never client-settable
        # (it directly reduces the agency's consolidated bill). It's set only via
        # the SaaS operator path; here it falls back to the column default (0).
        agency = Agency.new(
          owner: current_user,
          name: params[:name],
          billing_email: params[:billing_email]
        )

        if agency.save
          render json: { agency: AgencySerializer.new(agency).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(agency.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def update
        agency = current_user_agency

        if agency.update(agency_params)
          render json: { agency: AgencySerializer.new(agency).to_h }
        else
          render json: ErrorSerializer.serialize(agency.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def add_organization
        agency = current_user_agency
        org = current_user.accessible_organizations.find_by!(key: params[:org_id])
        return unless require_org_owner!(org)

        org.update!(agency: agency)
        render json: { agency: AgencySerializer.new(agency.reload).to_h }
      end

      def remove_organization
        agency = current_user_agency
        org = agency.organizations.find_by!(key: params[:org_id])
        return unless require_org_owner!(org)

        org.update!(agency: nil)
        render json: { agency: AgencySerializer.new(agency.reload).to_h }
      end

      def billing_summary
        agency = current_user_agency
        orgs = agency.organizations.includes(:domains, :subscription).map { |org| OrganizationSerializer.new(org).to_h }

        render json: {
          agency_id: agency.key,
          organizations: orgs,
          total_organizations: agency.total_organizations,
          discount_percent: agency.discount_percent,
          monthly_cost_cents: agency.consolidated_monthly_cost_cents
        }
      end

      private

      # Placing an org under (or removing it from) an agency is an ownership-level,
      # billing-affecting decision — only the org's owner may do it. Returns true
      # when allowed; renders 403 and returns false otherwise.
      def require_org_owner!(org)
        owner = org.owner_id == current_user.id ||
          org.memberships.exists?(user: current_user, status: Membership::STATUS_ACTIVE, role: Membership::ROLE_OWNER)
        return true if owner

        render json: ErrorSerializer.serialize("Only the organization owner can do this", status: 403), status: :forbidden
        false
      end

      def current_user_agency
        Agency.find_by!(owner: current_user)
      end

      def agency_params
        # discount_percent intentionally excluded — platform-granted, not self-set.
        params.permit(:name, :billing_email)
      end
    end
  end
end
