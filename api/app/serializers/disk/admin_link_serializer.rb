module Disk
  # A public link in the console's list: the link plus the item it opens and
  # where that is. params: paths ({ node id => chain }).
  class AdminLinkSerializer < Disk::LinkSerializer
    attribute :node do |l|
      Disk::NodeWithPathSerializer.new(l.node, params: { path: params[:paths]&.[](l.node_id) || [] }).to_h
    end
  end
end
