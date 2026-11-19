module Disk
  # Mail integration (spec F9) for inbox2-hosted (MX) mail: saving a message
  # attachment into Disk, and attaching a Disk file to a draft. The two
  # stores can differ (attachments on Garage, Disk on R2), so the bytes go
  # through a temp file in the API process, bounded by the plan's mail size
  # limit. Sealed mail and sealed files stay with the sealing client: the
  # server cannot read either (build guide 6 defines no server path for them).
  class MailBridge
    attr_reader :membership

    def initialize(membership)
      @membership = membership
    end

    # Returns the new node, or the file that took a new version.
    def save(attachment, parent_key:, name: nil, on_conflict: nil)
      message = attachment.message
      # A sealed attachment is ciphertext under the domain key; the
      # sealing client decrypts it and uploads it as a sealed or plain file itself.
      raise Disk::Refused, "Sealed mail attachments are saved by the sealing client" if message.sealed? || attachment.sealed?
      raise Disk::Refused.new("This attachment's content is not available", status: 404) if attachment.storage_key.blank?

      name = name.presence || attachment.filename.presence || "attachment"
      node, = Tempfile.create(["disk-mail", File.extname(name)], binmode: true) do |file|
        digest = Digest::SHA256.new
        S3StorageService.new.stream(attachment.storage_key) do |chunk|
          file.write(chunk)
          digest << chunk
        end
        file.flush
        file.rewind
        Disk::UploadOps.new(membership).write(bytes: file, size: file.size, sha256: digest.hexdigest,
                                              parent_key: parent_key, name: name, on_conflict: on_conflict)
      end
      Disk::Event.record!(Disk::Event::ACTION_SAVED_FROM_MAIL, actor: membership, node: node, name: node.name,
                                                               from: message.from_address, subject: message.subject,
                                                               message: message.key)
      node
    end

    # Copies a Disk file into the mail store as an attachment of draft.
    def attach(node, draft)
      raise Disk::Refused, "Only files can be attached" unless node.kind == Disk::Node::KIND_FILE && node.current_version
      raise Disk::Refused, "This file is in the trash" if node.trashed?
      # The sealing client decrypts a sealed file and attaches the plaintext itself.
      raise Disk::Refused, "Sealed files are attached by the sealing client" if node.sealed?

      # The send is refused above OutboundMailPublisher's cap (25 MB of attachments, what most
      # mail servers accept), whatever the plan's size limit says, so the link is offered from
      # there: a file that would attach and then not send helps nobody (spec F9, 2026-11-09).
      limit = [membership.organization.effective_mail_size_limit, OutboundMailPublisher::MAX_ATTACHMENT_BYTES].min
      if draft.attachments.sum(:size_bytes) + node.size_bytes > limit
        raise Disk::Refused.new("This would take the mail over #{limit / 1.megabyte} MB. Send it as a Disk link.",
                                code: "disk_attachment_too_large", limit_bytes: limit)
      end

      key = Tempfile.create(["disk-attach", File.extname(node.name)], binmode: true) do |file|
        Disk::Storage.current.read_into(node.current_version.storage_key, file)
        file.rewind
        S3StorageService.new.upload(file, filename: node.name, content_type: node.mime || "application/octet-stream",
                                          organization_key: membership.organization.key)
      end
      membership.organization.attachments.create!(message: draft, filename: node.name, size_bytes: node.size_bytes,
                                                  content_type: node.mime || "application/octet-stream", storage_key: key)
    end
  end
end
