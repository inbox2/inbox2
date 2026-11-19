module Api
  module V1
    module Disk
      # Public links on unsealed files and folders, managed by the item's
      # managers. The visitor side is PublicLinksController.
      class LinksController < BaseController
        # GET /nodes/:node_id/links — live and expired links; revoked ones are gone.
        def index
          node = manageable!(find_node!(params[:node_id]))
          links = node_links(node).active.includes(:node, created_by: :user).order(created_at: :desc)
          render json: { links: ::Disk::LinkSerializer.new(links).to_h }
        end

        # POST /nodes/:node_id/links { password, expires_at, hide_download }
        # A sealed file (build guide 6.9): { id, version_id, kdf_salt, wrapped_payload,
        # password_verifier, expires_at, hide_download }; its url has no name and the
        # client appends #<secret>.
        # The response carries the token and url once; they cannot be read again.
        def create
          seal = params.permit(:id, :version_id, :kdf_salt, :wrapped_payload, :password_verifier).to_h.symbolize_keys
          link, token = ops.create_link(find_node!(params[:node_id]), password: params[:password],
                                                                      expires_at: params[:expires_at],
                                                                      hide_download: params[:hide_download], seal: seal)
          render json: { link: ::Disk::LinkSerializer.new(link, params: { token: token }).to_h }, status: :created
        end

        # DELETE /links/:id — stops resolving at once.
        def destroy
          ops.revoke_link(ops.find_link!(params[:id]))
          head :no_content
        end

        private

        def node_links(node) = ::Disk::Link.where(node_id: node.id)

        def manageable!(node)
          raise ::Disk::Refused, "This item is in the trash" if node.trashed?

          ops.require_role!(node, ::Disk::ROLE_MANAGE)
          node
        end
      end
    end
  end
end
