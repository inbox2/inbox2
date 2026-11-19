module Disk
  # Sealed nodes return their ciphertext metadata and never a name or MIME type.
  # params: starred_ids (Set of node ids starred by the viewer), shared_with
  # ({ node id => Disk::SharedWith::Entry }), org_key.
  class NodeSerializer < ::ApplicationSerializer
    attributes :kind, :sealed, :size_bytes, :content_modified_at, :created_at, :trashed_at, :short_id

    attribute :name do |n|
      n.sealed? ? nil : n.name
    end

    attribute :mime do |n|
      n.sealed? ? nil : n.mime
    end

    attribute :metadata_ciphertext do |n|
      n.sealed? && n.metadata_ciphertext ? Base64.strict_encode64(n.metadata_ciphertext) : nil
    end

    attribute :key_epoch do |n|
      n.sealed? ? n.key_epoch : nil
    end

    attribute :drive do |n|
      n.on_c_drive? ? "C" : "D"
    end

    attribute :parent_id do |n|
      n.parent&.key
    end

    attribute :share_id do |n|
      n.share&.key
    end

    attribute :current_version_id do |n|
      n.current_version&.key
    end

    # Whether GET /versions/:current_version_id/download?variant=thumbnail has
    # anything to give. Listings preload current_version, so no extra queries.
    attribute :has_thumbnail do |n|
      n.current_version&.thumbnail_storage_key.present? || false
    end

    attribute :starred do |n|
      params[:starred_ids]&.include?(n.id) || false
    end

    # Set where the caller loaded it (Disk::SharedWith): listings and single-node responses.
    attribute :shared_with do |n|
      entry = params[:shared_with]&.[](n.id)
      entry && Disk::SharedWithSerializer.new(entry, params: params).to_h
    end

    one :modified_by, resource: Disk::MemberRefSerializer
  end
end
