module Api
  module V1
    module Disk
      # Shared with me, Recent, Starred, Trash.
      class ViewsController < BaseController
        # GET /views/shared-with-me — items granted to me by name, outside my own C:\.
        def shared_with_me
          rel = live.where(id: ::Disk::Grant.where(membership_id: membership.disk_ids).select(:node_id))
            .where("disk_nodes.custodian_membership_id IS DISTINCT FROM ?", membership.personal_membership_id)
            .order(Arel.sql("lower(disk_nodes.name), disk_nodes.id"))
          render_page(rel)
        end

        # GET /views/recent
        def recent
          render_page(live.joins("JOIN disk_recents r ON r.node_id = disk_nodes.id")
            .where("r.membership_id IN (?)", membership.disk_ids).order(Arel.sql("r.created_at DESC, disk_nodes.id DESC")))
        end

        # GET /views/starred
        def starred
          render_page(live.joins("JOIN disk_stars s ON s.node_id = disk_nodes.id")
            .where("s.membership_id IN (?)", membership.disk_ids).order(Arel.sql("s.created_at DESC, disk_nodes.id DESC")))
        end

        # GET /views/trash — what I deleted, and anything deleted from my C:\.
        def trash
          rel = node_scope.merge(visible_nodes).where(trash_root: true)
            .where("disk_nodes.trashed_by_membership_id IN (:m) OR disk_nodes.custodian_membership_id IN (:m)", m: membership.disk_ids)
            .order(trashed_at: :desc, id: :desc)
          render_page(rel)
        end

        private

        def live = node_scope.merge(visible_nodes).live

        def render_page(rel)
          rows, next_cursor = paginate_cursor(rel)
          render json: { nodes: nodes_json(rows), next_cursor: next_cursor }
        end
      end
    end
  end
end
