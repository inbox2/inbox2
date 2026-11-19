module Api
  module V1
    module Disk
      # The visitor side of a public link: unauthenticated, outside any org,
      # rate limited per IP and per token (config/initializers/rack_attack.rb).
      # Unknown, revoked, expired and trashed links, and links of an org without
      # Disk or with links turned off, all answer the same 404, so the endpoint
      # never confirms which tokens exist. A folder link reaches its own
      # subtree and nothing else; pages are not served, and sealed items only
      # through a sealed file link (build guide 6.9): its salt before unlock,
      # then the wrapped payload, the pinned version's manifest and a
      # ciphertext URL. The server never sees the secret in the fragment.
      class PublicLinksController < Api::V1::BaseController
        skip_before_action :authenticate_user!
        skip_before_action :enforce_api_key_scope!

        UNLOCK_HEADER = "X-Disk-Link-Unlock".freeze
        PAGE_LIMIT = 100

        # GET /api/v1/disk/links/:token?node_id=&cursor=
        # For a folder link, lists node_id (default: the linked folder).
        def show
          link = find_link!
          unlocked = link.unlocked_by?(request.headers[UNLOCK_HEADER])
          link.update_column(:last_used_at, Time.current)
          body = { link: ::Disk::PublicLinkSerializer.new(link, params: { unlocked: unlocked }).to_h,
                   folder: nil, path: [], nodes: [], next_cursor: nil }
          if unlocked && link.node.folder?
            folder = reach!(link, params[:node_id].presence || link.node.key)
            raise ActiveRecord::RecordNotFound unless folder.folder?

            rows, next_cursor = page(link.reachable.where(parent_id: folder.id)
              .order(Arel.sql("(disk_nodes.kind = 'folder') DESC, lower(disk_nodes.name), disk_nodes.id")))
            path = ::Disk::Node.paths_for(folder)[folder.id].drop_while { |n| n.id != link.node_id }
            body.merge!(folder: node_json(folder), path: node_json(path), nodes: node_json(rows), next_cursor: next_cursor)
          end
          render json: body
        end

        # POST /api/v1/disk/links/:token/unlock { password } or, sealed, { verifier (base64) }
        def unlock
          link = find_link!
          raise ActiveRecord::RecordNotFound unless link.password?
          unless link.password_matches?(link.sealed? ? params[:verifier] : params[:password])
            return render json: ErrorSerializer.serialize("Wrong password", status: 403), status: :forbidden
          end

          unlock = ::Disk::UnlockSerializer::Unlock.new(token: link.unlock_token,
                                                        expires_at: ::Disk::Link::UNLOCK_TTL.from_now)
          render json: { unlock: ::Disk::UnlockSerializer.new(unlock).to_h }
        end

        # GET /api/v1/disk/links/:token/download?node_id=
        # node_id defaults to the linked file; for a folder link it is a file in its subtree.
        def download
          link = find_link!
          unless link.unlocked_by?(request.headers[UNLOCK_HEADER])
            return render json: ErrorSerializer.serialize("This link needs its password", status: 403), status: :forbidden
          end

          node = reach!(link, params[:node_id].presence || link.node.key)
          version = link.sealed? ? link.version : node.current_version # a sealed link is pinned to its version
          raise ActiveRecord::RecordNotFound unless node.kind == ::Disk::Node::KIND_FILE && version

          key = version.storage_key
          storage = ::Disk::Storage.current
          dl = ::Disk::PublicDownloadSerializer::Download.new(
            node: node, preview_url: storage.preview_url(key), expires_at: ::Disk::Storage::GET_URL_TTL.from_now,
            url: link.hide_download ? nil : storage.get_url(key, filename: node.sealed? ? nil : node.name)
          )
          link.update_column(:last_used_at, Time.current)
          ::Disk::Event.record!(::Disk::Event::ACTION_LINK_USED, actor: nil, node: node, link: link)
          render json: { download: ::Disk::PublicDownloadSerializer.new(dl).to_h }
        end

        private

        def find_link!
          link = ::Disk::Link.includes(:organization, :version, node: :share)
            .find_by(token_digest: ::Disk::Link.digest(params[:token]))
          raise ActiveRecord::RecordNotFound unless link&.resolvable?

          link
        end

        def reach!(link, key) = link.reachable.find_by!(key: key.to_s)

        def node_json(nodes) = ::Disk::PublicNodeSerializer.new(nodes).to_h

        def page(relation)
          offset = params[:cursor].to_s.match?(/\A\d+\z/) ? params[:cursor].to_i : 0
          rows = relation.offset(offset).limit(PAGE_LIMIT + 1).to_a
          [rows.first(PAGE_LIMIT), rows.size > PAGE_LIMIT ? (offset + PAGE_LIMIT).to_s : nil]
        end
      end
    end
  end
end
