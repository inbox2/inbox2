module Disk
  # One node with its visible path and the viewer's access.
  # params: path, sources (Disk::Access sources), role, starred_ids.
  class NodeDetailSerializer < Disk::NodeWithPathSerializer
    # Where the file came from when it was saved from mail: from, subject, message.
    attribute :origin do |_n|
      params[:origin]
    end

    attribute :access do |_n|
      { role: params[:role], sources: Disk::AccessSourceSerializer.new(params[:sources] || []).to_h }
    end
  end
end
