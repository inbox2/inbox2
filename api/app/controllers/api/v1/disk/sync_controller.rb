module Api
  module V1
    module Disk
      # The Disk sync feed for a local mirror (macOS File Provider), modelled on
      # the MX feed (docs/Disk-Sync.md, docs/MX-Sync.md):
      #
      #   GET disk/sync/head    cursor for "now"
      #   GET disk/sync/pull    nodes changed since a cursor, plus deletes and a reconcile flag
      #   GET disk/sync/keys    every live node the member sees, with its version
      #   GET disk/sync/nodes   nodes by id, for what keys or pull flagged
      #
      # Candidates are the nodes and events of the orgs the member's Disk spans:
      # this team, their personal workspace (C:\) and the orgs of nodes granted to
      # them. Disk::Access.scope_for decides what the member gets; a changed node
      # it does not return, or one in the trash or staged, comes back in deleted.
      # Access changes that touch no node ("acl" events) set reconcile.
      #
      # Read-only; writes go through the normal Disk endpoints.
      class SyncController < BaseController
        include SyncCursor

        DEFAULT_LIMIT = 200
        MAX_LIMIT = 500
        KEYS_LIMIT = 5000
        NODES_MAX = 200

        def head
          render json: { cursor: encode_cursor(horizon, 0) }
        end

        def pull
          xid, seq = decode_cursor(params[:since])
          return render_bad_cursor if xid.nil?

          limit = clamp(params[:limit], DEFAULT_LIMIT, MAX_LIMIT)
          hi = horizon
          # A cursor from another database (see Api::V1::SyncController#pull):
          # restart at now and flag it expired.
          from_elsewhere = xid > next_xid
          xid, seq = hi, 0 if from_elsewhere
          rows = changed_rows(xid, seq, hi, limit + 1)
          has_more = rows.size > limit
          rows = rows.first(limit)

          by_type = rows.group_by { |r| r[:type] }
          node_keys = Array(by_type["node"]).map { |r| r[:key] }
          gone_keys = Array(by_type[::Disk::SyncEvent::KIND_DELETED]).map { |r| r[:key] }
          live = live_nodes.where(key: (node_keys + gone_keys).uniq).to_a
          live_keys = live.to_set(&:key)
          changed = node_keys.to_set
          expired = from_elsewhere || cursor_expired?(xid)

          render json: {
            cursor: next_cursor(has_more, rows.last, hi, xid, seq),
            has_more: has_more,
            cursor_expired: expired,
            reconcile: expired || by_type.key?(::Disk::SyncEvent::KIND_ACL),
            nodes: sync_nodes_json(live.select { |n| changed.include?(n.key) }),
            deleted: (node_keys + gone_keys).uniq.reject { |k| live_keys.include?(k) }
          }
        end

        # Keyset on the public key (E5).
        def keys
          rows = live_nodes.where("disk_nodes.key > ?", params[:after].to_s).order(:key)
            .limit(KEYS_LIMIT + 1).pluck(:key, :change_seq)
          more = rows.size > KEYS_LIMIT
          rows = rows.first(KEYS_LIMIT)
          render json: { keys: rows.map { |key, change_seq| [key, change_seq.to_i] }, next: more ? rows.last[0] : nil }
        end

        def nodes
          asked = Array(params[:ids]).map(&:to_s).uniq
          return render_error("Ask for at most #{NODES_MAX} ids at a time", 422) if asked.size > NODES_MAX

          found = live_nodes.where(key: asked).to_a
          render json: { nodes: sync_nodes_json(found), missing: asked - found.map(&:key) }
        end

        private

        # What the mirror holds: visible, not in the trash, not staged, not in a trashed share.
        def live_nodes
          visible_nodes.where(trashed_at: nil, pending_until: nil)
            .where("disk_nodes.share_id IS NULL OR disk_nodes.share_id IN (#{::Disk::Share.live.select(:id).to_sql})")
        end

        def feed_org_ids
          @feed_org_ids ||= [
            current_organization.id,
            membership.personal_membership_id && Membership.where(id: membership.personal_membership_id).pick(:organization_id),
            *::Disk::Grant.where(membership_id: membership.disk_ids).joins(:node).distinct.pluck("disk_nodes.organization_id")
          ].compact.uniq
        end

        # One ordered walk over disk_nodes and disk_sync_events, one branch per
        # org so each reads the cursor index in order.
        def changed_rows(xid, seq, hi, limit)
          sources = { "disk_nodes" => "'node' AS type, key", "disk_sync_events" => "kind AS type, node_key AS key" }
          branches = feed_org_ids.product(sources.to_a).map do |org_id, (table, cols)|
            <<~SQL
              (SELECT #{cols}, change_xid, change_seq FROM #{table}
               WHERE organization_id = #{org_id.to_i} AND change_seq IS NOT NULL
                 AND (change_xid, change_seq) > (:xid, :seq)
                 AND (change_xid < :hi OR change_xid = pg_current_xact_id_if_assigned()::text::bigint)
               ORDER BY change_xid, change_seq LIMIT :limit)
            SQL
          end
          sql = ApplicationRecord.sanitize_sql([
            "#{branches.join(' UNION ALL ')} ORDER BY change_xid, change_seq LIMIT :limit",
            { xid: xid, seq: seq, hi: hi, limit: limit }
          ])
          ActiveRecord::Base.connection.select_all(sql).map do |r|
            { type: r["type"], key: r["key"], xid: r["change_xid"], seq: r["change_seq"] }
          end
        end

        def cursor_expired?(xid)
          return false if xid.zero?

          watermark = ::Disk::SyncEvent.watermark_xid(feed_org_ids)
          watermark.present? && xid < watermark
        end

        def sync_nodes_json(nodes)
          return [] if nodes.empty?

          nodes = ::Disk::Node.where(id: nodes.map(&:id)).includes(:parent, :share, :current_version)
            .order(:change_xid, :change_seq).to_a
          roles = ::Disk::Access.roles_for(membership, nodes)
          scope_keys = ::Disk::Node.where(id: nodes.filter_map(&:seal_scope_node_id).uniq).pluck(:id, :key).to_h
          ::Disk::SyncNodeSerializer.new(nodes, params: { personal_membership_id: membership.personal_membership_id,
                                                         roles: roles, scope_keys: scope_keys }).to_h
        end
      end
    end
  end
end
