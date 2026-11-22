module Disk
  # A node as the Disk sync feed hands it out (docs/Disk-Sync.md). Sealed nodes
  # carry ciphertext, never a name or MIME type. params: personal_membership_id
  # (the viewer's, to tell their C:\), roles ({ node id => role }), scope_keys
  # ({ scope root id => key }).
  class SyncNodeSerializer < ::ApplicationSerializer
    attributes :kind, :sealed, :size_bytes, :content_modified_at, :updated_at

    attribute :parent_id do |n|
      n.parent&.key
    end

    # "c" for the viewer's own C:\, a share's id, or "shared" for a node on
    # someone else's C:\ that reaches the viewer through a grant.
    attribute :drive do |n|
      if n.share then n.share.key
      elsif n.custodian_membership_id == params[:personal_membership_id] then "c"
      else "shared"
      end
    end

    attribute :share_name do |n|
      # The share's own name is plaintext (ShareSerializer sends it for sealed shares
      # too); only node names inside a sealed scope are ciphertext.
      n.root? && n.share ? n.share.name : nil
    end

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

    attribute :seal_scope_id do |n|
      params[:scope_keys][n.seal_scope_node_id]
    end

    attribute :change_seq do |n|
      n.change_seq.to_i
    end

    attribute :current_version do |n|
      v = n.current_version
      next unless v

      out = { id: v.key, size_bytes: v.size_bytes, created_at: v.created_at }
      if v.sealed?
        out.merge!(chunk_bytes: v.chunk_bytes, key_epoch: v.key_epoch, wrapped_key: Base64.strict_encode64(v.wrapped_key),
                   manifest_ciphertext: v.manifest_ciphertext && Base64.strict_encode64(v.manifest_ciphertext))
      end
      out
    end

    attribute :can_write do |n|
      Disk.role_rank(params[:roles][n.id]) >= Disk.role_rank(Disk::ROLE_EDIT)
    end
  end
end
