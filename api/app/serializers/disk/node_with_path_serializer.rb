module Disk
  # A node with the part of its path the viewer can see (search results).
  # params: path, starred_ids.
  class NodeWithPathSerializer < Disk::NodeSerializer
    attribute :path do |_n|
      Disk::PathSegmentSerializer.new(params[:path] || []).to_h
    end
  end
end
