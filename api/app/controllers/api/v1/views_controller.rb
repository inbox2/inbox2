module Api
  module V1
    class ViewsController < BaseController
      before_action :require_organization!

      # spec 3.2.x, 3.3.5, A10.1
      def index
        View.ensure_system_views(current_organization)
        membership = current_active_membership!

        views = current_organization.views
          .where(kind: View::KIND_SYSTEM)
          .or(current_organization.views.where(kind: View::KIND_PERSONAL, membership: membership))
          .ordered

        render json: { views: views.map { |v| ViewSerializer.new(v).to_h } }
      end

      # spec 3.3.1, A10.2
      def create
        membership = current_active_membership!

        # Check view-creation policy
        if current_organization.view_creation_policy == Organization::VIEW_POLICY_ADMINS_ONLY
          require_role!(*Membership::ADMIN_ROLES)
        end

        view = current_organization.views.build(view_params.merge(
          kind: View::KIND_PERSONAL,
          membership: membership,
          position: current_organization.views.personal_for(membership).count
        ))

        if view.save
          render json: { view: ViewSerializer.new(view).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(view.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # spec A10.3
      def update
        membership = current_active_membership!
        view = current_organization.views.find_by!(key: params[:id], kind: View::KIND_PERSONAL, membership: membership)

        if view.update(view_params)
          render json: { view: ViewSerializer.new(view).to_h }
        else
          render json: ErrorSerializer.serialize(view.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # spec A10.3
      def destroy
        membership = current_active_membership!
        view = current_organization.views.find_by!(key: params[:id], kind: View::KIND_PERSONAL, membership: membership)

        view.destroy!
        head :no_content
      end

      # spec 3.3.1, A10.8
      def update_policy
        require_role!(*Membership::ADMIN_ROLES)

        policy = params[:view_creation_policy]
        unless Organization::VIEW_POLICIES.include?(policy)
          return render json: ErrorSerializer.serialize("Invalid policy", status: 422), status: :unprocessable_content
        end

        current_organization.update!(view_creation_policy: policy)
        render json: { view_creation_policy: current_organization.view_creation_policy }
      end

      # spec 3.3.6, A10.4 — Share a view
      def share
        require_role!(*Membership::ADMIN_ROLES)

        view = current_organization.views.find_by!(key: params[:id])
        view.update!(kind: View::KIND_SYSTEM, membership: nil) # system views are visible to all
        render json: { view: ViewSerializer.new(view).to_h }
      end

      # spec 3.3.7, A10.5 — Unread counts per view
      def counts
        View.ensure_system_views(current_organization)
        membership = current_active_membership!

        views = current_organization.views
          .where(kind: View::KIND_SYSTEM)
          .or(current_organization.views.where(kind: View::KIND_PERSONAL, membership: membership))

        # Single aggregate instead of one COUNT(*) per view. The previous loop
        # ignored `v` and recomputed the same org-wide unread count per row.
        # (Per-view filter-aware counts are a separate enhancement.)
        unread_count = visible_conversations.where(status: Conversation::STATUS_OPEN, read: false).count

        counts = views.map do |v|
          { id: v.key, name: v.name, unread_count: unread_count }
        end

        render json: { counts: counts }
      end

      # spec 3.3.8 — Smart suggested views
      def suggestions
        suggester = ViewSuggester.new(current_organization, conversations: visible_conversations)
        render json: { suggestions: suggester.suggest }
      end

      # spec 6.3.4, A10.7 — Save search as view
      def save_search
        membership = current_active_membership!
        view = current_organization.views.create!(
          name: params[:name] || "Search: #{params[:query]}",
          kind: View::KIND_PERSONAL,
          membership: membership,
          filters: [{ "field" => "search", "operator" => "contains", "value" => params[:query] }],
          position: current_organization.views.personal_for(membership).count
        )
        render json: { view: ViewSerializer.new(view).to_h }, status: :created
      end

      private

      def view_params
        params.permit(:name, :icon, filters: [:field, :operator, :value])
      end
    end
  end
end
