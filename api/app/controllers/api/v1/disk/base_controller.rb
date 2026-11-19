module Api
  module V1
    module Disk
      # Shared gate for every Disk endpoint (docs/plans/disk-build.md section 3).
      # Inside Api::V1::Disk, the models are ::Disk::*.
      class BaseController < Api::V1::BaseController
        PAGE_LIMIT = 100

        before_action :require_organization!
        before_action :require_disk!

        rescue_from ::Disk::Refused do |e|
          render_error(e.message, e.status, **e.extra)
        end
        rescue_from Aws::Errors::ServiceError, Seahorse::Client::NetworkingError do |e|
          Rails.logger.error("[Disk] storage: #{e.class}: #{e.message}")
          render_error("File storage isn't available. Try again shortly.", 503)
        end
        rescue_from ::Disk::Node::NameTaken do |e|
          render_error("An item named \"#{e.message}\" already exists here", 409)
        end
        rescue_from ActiveRecord::RecordNotUnique do
          render_error("That name is already taken", 409)
        end

        private

        # Not a member -> 404 (current_active_membership!); a plan without Disk
        # -> 403. In the read-only month after a downgrade (spec F8) reads, deletes
        # and offboarding still work and everything else is 403 disk_read_only.
        def require_disk!
          return if performed?

          current_active_membership!
          case current_organization.disk_state
          when Organization::DISK_ACTIVE then nil
          when Organization::DISK_READ_ONLY
            return if request.get? || request.head? || read_only_allowed?

            until_on = (current_organization.disk_lost_at + Organization::DISK_READ_ONLY_DAYS.days).to_date
            render_error("Disk is read-only on this plan until #{until_on}. You can still view, download and delete files.",
                         403, code: READ_ONLY)
          else render_error("Disk is not included in this organization's plan", 403)
          end
        end

        READ_ONLY = "disk_read_only".freeze
        # Writes that stay open while Disk is read-only: deleting, cancelling,
        # revoking, reporting and settings.
        READ_ONLY_ACTIONS = %w[
          nodes#destroy nodes#purge nodes#preview_failures uploads#destroy links#destroy shares#destroy shares#purge
          admin#settings admin#revoke_link agent_grants#destroy
          imports#destroy imports#disconnect
        ].freeze

        def read_only_allowed?
          action = "#{controller_name}##{action_name}"
          READ_ONLY_ACTIONS.include?(action) || (action == "nodes#bulk" && params[:op].to_s == "trash")
        end

        def membership = current_active_membership!
        def ops = @ops ||= ::Disk::NodeOps.new(membership)
        def visible_nodes = ::Disk::Access.scope_for(membership)
        def find_node!(key) = visible_nodes.find_by!(key: ::Disk::Node.key_for(key))
        def admin? = membership.admin?

        def require_admin!
          raise ::Disk::Refused.new("Only owners and admins can do this", status: 403) unless admin?
        end

        def keep_both? = params[:on_conflict].to_s == "keep_both"

        def render_error(message, status, **extra)
          render json: ErrorSerializer.serialize(message, status: status).merge(extra), status: status
        end

        # Opaque offset cursor. ponytail: offset paging; switch to keyset if
        # folders grow past tens of thousands of rows.
        def paginate_cursor(relation)
          offset = params[:cursor].to_s.match?(/\A\d+\z/) ? params[:cursor].to_i : 0
          limit = (params[:limit] || PAGE_LIMIT).to_i.clamp(1, PAGE_LIMIT)
          rows = relation.offset(offset).limit(limit + 1).to_a
          [rows.first(limit), rows.size > limit ? (offset + limit).to_s : nil]
        end

        def starred_ids(nodes)
          ::Disk::Star.where(membership_id: membership.disk_ids, node_id: nodes.map(&:id)).pluck(:node_id).to_set
        end

        def node_json(node) = ::Disk::NodeSerializer.new(node, params: node_params([node])).to_h
        def nodes_json(nodes) = ::Disk::NodeSerializer.new(nodes, params: node_params(nodes)).to_h

        # Per-viewer extras for a page of nodes, each loaded in one go.
        def node_params(nodes)
          { starred_ids: starred_ids(nodes), shared_with: ::Disk::SharedWith.for(nodes),
            org_key: current_organization.key }
        end

        def node_scope = ::Disk::Listing.node_scope
        def listing_opts = params.permit(:sort, :dir, :type, :modified, :tz, :since, :by, :sealed).to_h

        # A presigned GET for a version's bytes, or its thumbnail or rendition.
        # Only reachable through a visible node, so access is checked at issue.
        def render_download(version, variant = nil)
          key = variant ? version.public_send("#{variant}_storage_key") : version.storage_key
          raise ::Disk::Refused.new("This version has no #{variant}", status: 404) unless key

          url = ::Disk::Storage.current.get_url(key, filename: download_filename(version.node, variant))
          download = ::Disk::DownloadSerializer::Download.new(
            url: url, expires_at: ::Disk::Storage::GET_URL_TTL.from_now, version: version, variant: variant
          )
          render json: { download: ::Disk::DownloadSerializer.new(download).to_h }
        end

        # Sealed names never reach the server, so sealed downloads are nameless.
        def download_filename(node, variant)
          return if node.sealed? || variant == ::Disk::Version::VARIANT_THUMBNAIL
          return "#{File.basename(node.name, '.*')}.pdf" if variant == ::Disk::Version::VARIANT_RENDITION

          node.name
        end

        # Each node's path trimmed to what the viewer can see, so a grantee never
        # learns the names of the folders above what was shared with them.
        def visible_paths(nodes)
          paths = ::Disk::Node.paths_for(nodes)
          seen = visible_nodes.where(id: paths.values.flatten.map(&:id)).pluck(:id).to_set
          paths.transform_values { |chain| chain.select { |n| seen.include?(n.id) } }
        end
      end
    end
  end
end
