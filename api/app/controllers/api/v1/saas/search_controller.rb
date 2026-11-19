module Api
  module V1
    module Saas
      # Type-to-search across orgs and users — the lookup that drives "find the
      # right org/user fast". Returns the two result sets, each capped at 10.
      class SearchController < BaseController
        LIMIT = 10

        def index
          q = params[:q].to_s.strip
          return render(json: { organizations: [], users: [] }) if q.blank?

          like = "%#{q.downcase}%"

          orgs = Organization.left_joins(:domains)
            .where("LOWER(organizations.name) LIKE :q OR LOWER(organizations.slug) LIKE :q OR LOWER(domains.name) LIKE :q", q: like)
            .distinct.order(created_at: :desc).limit(LIMIT)
            # preload (separate queries) so the distinct join above isn't disturbed
            .preload(:owner, :domains, :subscription)

          users = User
            .where("LOWER(username) LIKE :q OR LOWER(display_name) LIKE :q OR LOWER(billing_email) LIKE :q", q: like)
            .includes(:owned_organizations, memberships: [{ mailboxes: :domain }, { organization: :domains }])
            .order(created_at: :desc).limit(LIMIT)

          render json: {
            organizations: orgs.map { |o| ::Saas::OrganizationSerializer.new(o).to_h },
            users: users.map { |u| ::Saas::UserSerializer.new(u).to_h }
          }
        end
      end
    end
  end
end
