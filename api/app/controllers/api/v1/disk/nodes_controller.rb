module Api
  module V1
    module Disk
      # Folders and nodes. The rules live in ::Disk::NodeOps, shared with bulk.
      class NodesController < BaseController
        BULK_ACTIONS = %w[move trash restore].freeze
        BULK_MAX = 200
        PREVIEW_CODE = /\A[a-z0-9][a-z0-9_.:-]{0,63}\z/i

        # GET /nodes/:id — the node, its visible path, and the viewer's access with its sources.
        def show
          node = node_scope.merge(visible_nodes).find_by!(key: ::Disk::Node.key_for(params[:id]))
          path = visible_paths([node])[node.id]
          sources = ::Disk::Access.sources(membership, node, path: ::Disk::Node.paths_for(node)[node.id])
          ::Disk::Recent.touch!(membership, node) unless node.folder?
          origin = ::Disk::Event.where(node_id: node.id, action: ::Disk::Event::ACTION_SAVED_FROM_MAIL).order(:id).last
          render json: { node: ::Disk::NodeDetailSerializer.new(node, params: {
            path: path, sources: sources, role: ::Disk::Access.role(membership, node),
            origin: origin&.detail&.slice("from", "subject", "message"), **node_params([node])
          }).to_h }
        end

        # GET /nodes/:id/children?sort=&dir=&type=&modified=&tz=&since=&by=&sealed=&cursor= (a page's children are its sub-pages)
        def children
          all, filtered = ::Disk::Listing.children(visible_nodes, find_node!(params[:id]), listing_opts,
                                                   current_organization)
          rows, next_cursor = paginate_cursor(filtered)
          render json: { nodes: nodes_json(rows), count: filtered.count, total: all.count, next_cursor: next_cursor }
        end

        # POST /nodes { parent_id, name, kind: "folder"|"page", on_conflict, staged }
        # A page may also go under another page (the page tree). Sealed (build
        # guide 6.5): { parent_id, kind, id, metadata_ciphertext, key_epoch }
        # inside a sealed folder; a new sealed C:\ folder adds sealed: true and
        # sealed_key (the creator's key grant at epoch 1).
        def create
          kind = params[:kind].presence || ::Disk::Node::KIND_FOLDER
          kinds = [::Disk::Node::KIND_FOLDER, ::Disk::Node::KIND_PAGE]
          raise ::Disk::Refused, "kind must be folder or page" unless kinds.include?(kind)

          seal = params.permit(:id, :metadata_ciphertext, :key_epoch, :sealed_key).to_h.symbolize_keys if sealed_create?
          node = ops.create_folder(parent_key: params.require(:parent_id), name: seal ? nil : params.require(:name).to_s,
                                   keep_both: keep_both?, kind: kind, seal: seal, staged: bool(:staged))
          render json: { node: node_json(node) }, status: :created
        end

        # PATCH /nodes/:id { name, on_conflict } and/or { starred }; sealed: { metadata_ciphertext, key_epoch }
        def update
          node = find_node!(params[:id])
          if params.key?(:metadata_ciphertext)
            ops.rename_sealed(node, metadata_ciphertext: params[:metadata_ciphertext], key_epoch: params[:key_epoch])
          end
          ops.rename(node, params[:name].to_s, keep_both: keep_both?) if params.key?(:name)
          ops.star(node, ActiveModel::Type::Boolean.new.cast(params[:starred])) if params.key?(:starred)
          render json: { node: node_json(node) }
        end

        # POST /nodes/:id/move { target_id, on_conflict } — revoked lists the links,
        # grants and agent grants a move to another drive or share took away.
        # Into another sealed scope (build guide 6.8) add key_epoch, nodes: [{ id,
        # metadata_ciphertext }], versions: [{ id, wrapped_key }] and pages: [{ id,
        # sealed_snapshot, seq }] covering the whole subtree.
        def move
          node = ops.move(find_node!(params[:id]), target_key: params.require(:target_id), keep_both: keep_both?,
                                                   rewrap: rewrap_params)
          render json: { node: node_json(node.reload), revoked: ::Disk::RevokedSerializer.new(ops.revoked).to_h }
        end

        # POST /nodes/:id/copy { target_id, on_conflict: keep_both|replace }
        # replace on a file adds a version to the same-named file at the target.
        # A sealed file answers { upload } instead: the copied object's reservation,
        # made visible by POST /uploads/:id/complete with the re-sealed fields (6.8).
        def copy
          copied = ops.copy(find_node!(params[:id]), target_key: params.require(:target_id), keep_both: keep_both?,
                                                     replace: params[:on_conflict].to_s == "replace")
          return render json: { upload: ::Disk::UploadSerializer.new(copied).to_h }, status: :created if copied.is_a?(::Disk::Upload)

          render json: { node: node_json(copied) }, status: :created
        end

        # POST /nodes/:id/switch { staged_id } — the staged node made across a seal
        # boundary takes this one's place, which is then purged (6.8).
        def switch
          node = ops.switch(find_node!(params[:id]), staged_key: params.require(:staged_id))
          render json: { node: node_json(node), revoked: ::Disk::RevokedSerializer.new(ops.revoked).to_h }
        end

        # DELETE /nodes/:id — to the trash.
        def destroy
          render json: { node: node_json(ops.trash(find_node!(params[:id]))) }
        end

        # POST /nodes/:id/restore
        def restore
          node, to_root = ops.restore(find_node!(params[:id]))
          render json: { node: node_json(node), restored_to_root: to_root }
        end

        # DELETE /nodes/:id/purge — delete forever.
        def purge
          ops.purge(find_node!(params[:id]), empty_only: ActiveModel::Type::Boolean.new.cast(params[:empty_only]))
          head :no_content
        end

        # GET /nodes/:id/download — a short-lived presigned GET for the current version.
        def download
          node = find_node!(params[:id])
          raise ::Disk::Refused, "Only files can be downloaded; zip folders in the browser" unless node.current_version

          render_download(node.current_version)
        end

        # GET /nodes/:id/tree?cursor= — every live item beneath a folder, flat and
        # paged, for building zips in the browser.
        def tree
          folder = find_node!(params[:id])
          raise ::Disk::Refused, "Only folders and pages have contents" unless folder.container?

          rel = node_scope.merge(visible_nodes).live.where(pending_until: nil).where.not(id: folder.id)
            .merge(::Disk::Node.subtree(folder.id, skip_trash_roots: true)).order(:id)
          rows, next_cursor = paginate_cursor(rel)
          render json: { nodes: nodes_json(rows), next_cursor: next_cursor }
        end

        # POST /nodes/bulk { op: move|trash|restore, ids: [...], target_id, on_conflict }
        # Per-item results; one refused item does not stop the rest.
        def bulk
          op = params.require(:op).to_s
          raise ::Disk::Refused, "op must be one of #{BULK_ACTIONS.join(', ')}" unless BULK_ACTIONS.include?(op)

          ids = Array(params.require(:ids)).map(&:to_s).uniq
          raise ::Disk::Refused, "Select up to #{BULK_MAX} items at a time" if ids.size > BULK_MAX

          results = ids.map { |id| bulk_one(op, id) }
          render json: { results: ::Disk::BulkResultSerializer.new(results, params: { starred_ids: Set.new }).to_h }
        end

        # GET /nodes/:id/events — a file's history; on a share's top folder, the share's.
        def events
          node = find_node!(params[:id])
          scope = ::Disk::Event.includes(:node, :share, :link, :actor_agent, actor: :user).order(created_at: :desc, id: :desc)
            .where.not(action: ::Disk::Event::ACTION_PREVIEW_FAILED)
          scope = node.root? && node.share_id ? scope.where(share_id: node.share_id) : scope.where(node_id: node.id)
          rows, next_cursor = paginate_cursor(scope)
          render json: { events: ::Disk::EventSerializer.new(rows).to_h, next_cursor: next_cursor }
        end

        # POST /nodes/:id/preview-failures { renderer, reason } — a preview that
        # failed in the browser (spec F5), counted for metrics. Kept out of the
        # activity feed. A sealed node's failure keeps only the renderer.
        def preview_failures
          node = find_node!(params[:id])
          renderer = params.require(:renderer).to_s
          reason = params[:reason].to_s
          raise ::Disk::Refused, "renderer must be a short code" unless renderer.match?(PREVIEW_CODE)
          raise ::Disk::Refused, "reason must be a short code" unless reason.empty? || reason.match?(PREVIEW_CODE)

          detail = node.sealed? ? { renderer: renderer } : { renderer: renderer, reason: reason.presence, mime: node.mime }
          ::Disk::Event.record!(::Disk::Event::ACTION_PREVIEW_FAILED, actor: membership, node: node, **detail.compact)
          head :no_content
        end

        private

        def bool(key) = ActiveModel::Type::Boolean.new.cast(params[key]) || false
        def sealed_create? = bool(:sealed) || params.key?(:metadata_ciphertext)

        def rewrap_params
          return unless params.key?(:nodes)

          params.permit(:key_epoch, nodes: %i[id metadata_ciphertext], versions: %i[id wrapped_key],
                                    pages: %i[id sealed_snapshot seq]).to_h
        end

        def bulk_one(op, id)
          node = ops.find!(id)
          node = case op
          when "move" then ops.move(node, target_key: params.require(:target_id), keep_both: keep_both?)
          when "trash" then ops.trash(node)
          when "restore" then ops.restore(node).first
          end
          ::Disk::BulkResultSerializer::Result.new(id: id, ok: true, node: node)
        rescue ::Disk::Refused, ::Disk::Node::NameTaken, ActiveRecord::RecordInvalid => e
          ::Disk::BulkResultSerializer::Result.new(id: id, ok: false, error: bulk_error(e))
        end

        def bulk_error(e)
          case e
          when ::Disk::Node::NameTaken then "An item named \"#{e.message}\" already exists there"
          when ActiveRecord::RecordInvalid then e.record.errors.full_messages.to_sentence
          else e.message
          end
        end
      end
    end
  end
end
