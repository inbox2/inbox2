module Disk
  # What a link visitor learns about the link. Until the password is given,
  # only that one is needed: no name, type or size.
  # params: unlocked (boolean).
  class PublicLinkSerializer
    include Alba::Resource

    ABUSE_EMAIL = ENV.fetch("DISK_ABUSE_EMAIL", "abuse@inbox2.com")

    attributes :expires_at, :hide_download

    attribute :password_required, &:password?

    attribute :unlocked do |_l|
      params[:unlocked]
    end

    attribute :download_allowed do |l|
      !l.hide_download
    end

    attribute :abuse_email do |_l|
      ABUSE_EMAIL
    end

    attribute :node do |l|
      params[:unlocked] ? Disk::PublicNodeSerializer.new(l.node).to_h : nil
    end

    # A sealed file link (build guide 6.9). Before unlocking: what the viewer
    # needs to derive the verifier. Unlocked: the wrapped payload and the
    # pinned version's manifest; the ciphertext comes from /download.
    attribute :sealed, &:sealed?
    attributes :kdf_version

    attribute :kdf_salt do |l|
      l.kdf_salt && Base64.strict_encode64(l.kdf_salt)
    end

    attribute :sealed_payload do |l|
      next nil unless l.sealed? && params[:unlocked]

      v = l.version
      { link_id: l.key, version_id: v.key, wrapped_payload: Base64.strict_encode64(l.wrapped_payload),
        manifest_ciphertext: Base64.strict_encode64(v.manifest_ciphertext), size_bytes: v.size_bytes,
        chunk_bytes: v.chunk_bytes }
    end
  end
end
