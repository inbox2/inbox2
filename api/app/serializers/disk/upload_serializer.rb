module Disk
  # A reserved upload. node_id and version_id are the ids the file and its new
  # version have (or will have once complete); part_bytes is fixed by the API.
  class UploadSerializer < ::ApplicationSerializer
    attributes :state, :declared_bytes, :part_bytes, :part_count, :sealed, :chunk_bytes, :key_epoch, :staged,
               :expires_at, :created_at

    attribute :node_id, &:node_key
    attribute :version_id, &:version_key

    attribute :parent_id do |u|
      u.parent&.key
    end
  end
end
