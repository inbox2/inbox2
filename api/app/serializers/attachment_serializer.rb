class AttachmentSerializer < ::ApplicationSerializer
  attributes :filename, :content_type, :size_bytes, :created_at

  # E2EE (docs/E2EE.md): sealed attachments serve filename as null plus the
  # sealed-filename blobs; ciphertext AAD derives from the message's aad +
  # the attachment's position ("|att:<i>", "|name").
  attributes :sealed_filename, :filename_nonce, :content_nonce

  attribute :has_content do |att|
    att.storage_key.present?
  end

  attribute :download_url do |att|
    if att.storage_key.present?
      "/api/v1/orgs/#{att.organization.key}/attachments/#{att.key}"
    end
  end
end
