module Api
  module V1
    module Disk
      # Page content (spec F6). Live editing runs over DiskPageChannel; a
      # client saves a snapshot here every so often. Restoring history is done
      # by the editor: it loads an old revision's content, applies it to the
      # live document and saves with restored_from, so collaborators converge.
      class PagesController < BaseController
        # GET /pages/:node_id
        def show
          node = page_node!
          render json: { page: page_json(::Disk::Page.for(node)), role: ::Disk::Access.role(membership, node) }
        end

        # PUT /pages/:node_id { ydoc (base64), markdown, base_revision, restored_from }
        # 409 { current_revision } when someone saved since base_revision.
        # Without ydoc the page is replaced from markdown, as an agent's write is
        # (a .docx imported in the browser); open editors rebuild from it.
        # Sealed (build guide 6.10): { sealed_snapshot, epoch, seq }, seq the
        # newest update the snapshot covers; 409 { update_seq, snapshot_seq,
        # current_epoch } when out of range or under another epoch.
        def update
          node = page_node!
          if node.sealed? && params.key?(:sealed_snapshot)
            page = ops.save_sealed_page(node, sealed_snapshot: params[:sealed_snapshot], epoch: params[:epoch], seq: params[:seq])
            return render json: { page: page_json(page), node: node_json(node.reload) }
          end

          page = ops.save_page(node, ydoc: params.key?(:ydoc) ? ydoc_param : nil, markdown: params.fetch(:markdown).to_s,
                                     base_revision: Integer(params.require(:base_revision).to_s, exception: false),
                                     restored_from: params[:restored_from].presence&.to_i)
          render json: { page: page_json(page), node: node_json(node.reload) }
        end

        # POST /pages/:node_id/updates { update (base64 envelope), epoch, seq } — a
        # sealed page update at exactly update_seq + 1 (6.10), relayed on
        # DiskPageChannel once stored. 409 { update_seq, snapshot_seq, current_epoch }.
        def updates
          row = ops.append_page_update(page_node!, update: params.require(:update), epoch: params.require(:epoch),
                                                   seq: params.require(:seq))
          render json: { update: ::Disk::PageUpdateSerializer.new(row).to_h }, status: :created
        end

        # GET /pages/:node_id/versions?cursor=&limit=
        def versions
          rows, next_cursor = paginate_cursor(::Disk::Page.for(page_node!).versions.includes(author: :user).order(revision: :desc))
          render json: { versions: ::Disk::PageVersionSerializer.new(rows).to_h, next_cursor: next_cursor }
        end

        # GET /pages/:node_id/versions/:revision — that revision's ydoc and markdown.
        def version
          row = ::Disk::Page.for(page_node!).versions.includes(author: :user).find_by!(revision: params[:revision].to_i)
          render json: { version: ::Disk::PageVersionSerializer.new(row, params: { content: true }).to_h }
        end

        private

        def page_node!
          node = find_node!(params[:node_id])
          raise ::Disk::Refused, "This is not a page" unless node.page?

          ::Disk::Recent.touch!(membership, node) if action_name == "show"
          node
        end

        def page_json(page) = ::Disk::PageSerializer.new(page).to_h

        def ydoc_param
          Base64.strict_decode64(params.fetch(:ydoc).to_s)
        rescue ArgumentError
          raise ::Disk::Refused, "ydoc must be base64"
        end
      end
    end
  end
end
