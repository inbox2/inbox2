module Api
  module V1
    # Spaces — org-defined classification buckets for MX (in-domain) mail.
    # Inbound mail is auto-triaged into a space by the cloud classifier; the
    # web/desktop treemap is sized by these per-space counts. MX-only: this
    # lives in the API/Postgres, not the offline local-channel SQLite.
    class SpacesController < BaseController
      before_action :require_organization!

      # GET /api/v1/orgs/:org_id/spaces
      def index
        Space.ensure_default_spaces(current_organization)
        spaces = current_organization.spaces.ordered.includes(memberships: :user).to_a
        decorate_with_stats!(spaces)
        render json: { spaces: spaces.map { |s| SpaceSerializer.new(s).to_h } }
      end

      # POST /api/v1/orgs/:org_id/spaces
      def create
        require_admin!
        return if performed?

        space = current_organization.spaces.build(space_params.except(:members))
        space.position ||= current_organization.spaces.count

        if space.save
          sync_members!(space, params[:members])
          render json: { space: SpaceSerializer.new(reload_decorated(space)).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(space.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # PATCH/PUT /api/v1/orgs/:org_id/spaces/:id
      def update
        require_admin!
        return if performed?

        space = current_organization.spaces.find_by!(key: params[:id])

        if space.update(space_params.except(:members))
          sync_members!(space, params[:members]) unless params[:members].nil?
          render json: { space: SpaceSerializer.new(reload_decorated(space)).to_h }
        else
          render json: ErrorSerializer.serialize(space.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # DELETE /api/v1/orgs/:org_id/spaces/:id
      def destroy
        require_admin!
        return if performed?

        space = current_organization.spaces.find_by!(key: params[:id])
        space.destroy!
        head :no_content
      end

      private

      def space_params
        params.permit(:name, :slug, :icon, :color, :openness, :alias_local, :description, :not_for, :classify, :position,
                      members: [])
      end

      def require_admin!
        require_role!(*Membership::ADMIN_ROLES)
      end

      # Replace a space's staffed members from a list of membership keys.
      def sync_members!(space, member_keys)
        return if member_keys.nil?

        keys = Array(member_keys).reject(&:blank?)
        memberships = current_organization.memberships.where(key: keys)
        space.memberships = memberships
      end

      def reload_decorated(space)
        space = current_organization.spaces.includes(memberships: :user).find(space.id)
        decorate_with_stats!([space])
        space
      end

      # Populate each space's transient stats + member summaries with a fixed
      # number of grouped queries over the org's conversations (no per-space N+1).
      def decorate_with_stats!(spaces)
        # The caller's slice of the pool, so a domain-scoped member's board
        # counts what they can open — not every domain's and nobody's imports.
        convs = visible_conversations
        # Volume is the board's "All items": every thread still real mail
        # (open, pending, archived) — trash and spam never count.
        volume_by = convs.where.not(status: Conversation::EMPTYABLE_STATUSES).group(:space_id).count
        # Unread is scoped to open: archived/trashed threads are "done" and no
        # longer part of the space's active queue, read or not.
        unread_by = convs.where(read: false, status: Conversation::STATUS_OPEN).group(:space_id).count
        open_by = convs.where(status: Conversation::STATUS_OPEN).group(:space_id).count
        unassigned_by = convs.where(status: Conversation::STATUS_OPEN)
          .where.missing(:conversation_assignees).group(:space_id).count

        known = current_active_membership!.teammates.pluck(:id).to_set
        spaces.each do |space|
          id = space.id
          space.stats = {
            volume: volume_by[id] || 0,
            unread: unread_by[id] || 0,
            open: open_by[id] || 0,
            unassigned: unassigned_by[id] || 0
          }
          space.member_summaries = space.memberships.select { |m| known.include?(m.id) }.map do |m|
            { key: m.key, name: m.user.display_name.presence || m.user.username, avatar_url: nil }
          end
        end
      end
    end
  end
end
