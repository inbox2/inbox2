module Disk
  # One entry in a file's history. Sealed versions add their wrapped key and
  # manifest (base64); the server cannot read either.
  class VersionSerializer < ::ApplicationSerializer
    attributes :number, :size_bytes, :sha256, :chunk_bytes, :key_epoch, :created_at, :expires_at

    attribute :node_id do |v|
      v.node.key
    end

    attribute :current do |v|
      v.node.current_version_id == v.id
    end

    attribute :has_thumbnail do |v|
      v.thumbnail_storage_key.present?
    end

    attribute :has_rendition do |v|
      v.rendition_storage_key.present?
    end

    attribute :wrapped_key do |v|
      v.wrapped_key && Base64.strict_encode64(v.wrapped_key)
    end

    attribute :manifest_ciphertext do |v|
      v.manifest_ciphertext && Base64.strict_encode64(v.manifest_ciphertext)
    end

    one :author, resource: Disk::MemberRefSerializer
  end
end
