module Api
  module V1
    module Disk
      # Name search over visible unsealed nodes. Sealed names are matched in the browser.
      class SearchController < BaseController
        # GET /search?q=&scope=<node id>|all&modified=&tz=&since=
        def index
          scope_node = find_node!(params[:scope]) if params[:scope].present? && params[:scope] != "all"
          nodes = ::Disk::Listing.search(visible_nodes, params[:q], listing_opts, scope_node: scope_node)
          paths = visible_paths(nodes)
          extras = node_params(nodes)
          render json: { results: nodes.map do |n|
            ::Disk::NodeWithPathSerializer.new(n, params: extras.merge(path: paths[n.id])).to_h
          end }
        end
      end
    end
  end
end
