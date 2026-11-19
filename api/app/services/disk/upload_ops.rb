module Disk
  # The upload protocol (docs/plans/disk-build.md section 8) for one member.
  # finish! and abort! are class methods because the jobs run them too.
  class UploadOps
    SHA256 = /\A\h{64}\z/

    attr_reader :membership

    def initialize(membership)
      @membership = membership
    end

    def ops = @ops ||= Disk::NodeOps.new(membership)

    def find!(key)
      Disk::Upload.where(membership_id: membership.id).find_by(key: key.to_s) || raise(Disk::Refused.new("Not found", status: 404))
    end

    # Step 1: reserve quota and start the multipart upload. Returns
    # [upload, created]; the same idempotency key returns the same upload.
    # Sealed (build guide 6.5, 6.6): size is the ciphertext size, and a new
    # file's id is proposed by the client (id) with its metadata_ciphertext.
    # staged: the new file stays invisible until switched in (6.8).
    def reserve(size:, parent_key: nil, node_key: nil, name: nil, on_conflict: nil, idempotency_key: nil,
                sealed: false, chunk_bytes: nil, key_epoch: nil, metadata_ciphertext: nil, multipart: true,
                id: nil, staged: false)
      if idempotency_key.present?
        existing = Disk::Upload.find_by(membership_id: membership.id, idempotency_key: idempotency_key.to_s)
        return [existing, false] if existing
      end
      size = Integer(size.to_s, exception: false)
      raise Disk::Refused, "size_bytes must be a whole number of bytes" if size.nil? || size.negative?

      parent, node = target_for(parent_key: parent_key, node_key: node_key, name: name, on_conflict: on_conflict)
      raise Disk::Refused, "Staging is for a new file" if staged && node
      attrs = sealed ? sealed_attrs(parent, node, chunk_bytes, key_epoch, metadata_ciphertext, size, id) : { intended_name: name.to_s.strip.presence }
      raise Disk::Refused, "This folder is sealed; upload through the sealing client" if !sealed && parent.sealed?

      [start!(size, parent, node, idempotency_key.presence&.to_s, attrs.merge(staged: staged), multipart: multipart), true]
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?("idempotency_key")

      [Disk::Upload.find_by!(membership_id: membership.id, idempotency_key: idempotency_key.to_s), false]
    end

    # Step 2: a presigned URL per requested part number, each recorded as issued.
    def issue_parts(upload, numbers)
      raise self.class.closed(upload, "This upload has ended. Start it again.") unless upload.reserved?

      numbers = Array(numbers).map { |n| Integer(n.to_s, exception: false) }.uniq
      if numbers.empty? || numbers.size > Disk::Upload::PARTS_PER_CALL
        raise Disk::Refused, "Ask for 1 to #{Disk::Upload::PARTS_PER_CALL} part numbers at a time"
      end
      unless numbers.all? { |n| n&.between?(1, upload.part_count) }
        raise Disk::Refused, "Part numbers run from 1 to #{upload.part_count} for this upload"
      end

      refusal = self.class.target_refusal(upload)
      raise refusal if refusal

      now = Time.current
      Disk::UploadPart.upsert_all(
        numbers.map { |n| { organization_id: upload.organization_id, upload_id: upload.id, number: n, issued_at: now } },
        unique_by: %i[upload_id number]
      )
      upload.update!(expires_at: now + Disk::Upload::TTL)
      storage = Disk::Storage.current
      numbers.map { |n| { number: n, url: storage.part_url(upload.storage_key, upload.multipart_upload_id, n) } }
    end

    # Step 3. Returns [node, version]. A repeat call on a finished upload returns the same pair.
    # metadata_ciphertext completes a sealed copy (reserve_copy), whose new node
    # id the client learnt from the reservation.
    def complete(upload, sha256: nil, wrapped_key: nil, manifest_ciphertext: nil, metadata_ciphertext: nil)
      return [upload.node, upload.version] if upload.done?
      raise self.class.closed(upload, "This upload was cancelled") if upload.aborted?

      if upload.reserved?
        attrs = { state: Disk::Upload::STATE_COMPLETING }
        if upload.sealed?
          attrs[:wrapped_key] = Disk::Sealing.bytes!(wrapped_key, "wrapped_key")
          attrs[:manifest_ciphertext] = Disk::Sealing.bytes!(manifest_ciphertext, "manifest_ciphertext")
          if upload.node_id.nil? && upload.intended_metadata_ciphertext.nil?
            attrs[:intended_metadata_ciphertext] = Disk::Sealing.bytes!(metadata_ciphertext, "metadata_ciphertext")
          end
        elsif sha256.present?
          raise Disk::Refused, "sha256 must be 64 hex digits" unless sha256.to_s.match?(SHA256)

          attrs[:sha256] = sha256.to_s.downcase
        end
        upload.with_lock { upload.update!(attrs) if upload.reserved? }
      end
      self.class.finish!(upload)
    end

    # A small unsealed file written by the API itself (an agent's text over
    # MCP): the same reservation, quota and commit as an upload, with the
    # bytes put in one request instead of parts. Returns [node, version].
    # bytes is a String, or an IO with size: and sha256: given. A file on disk
    # (an import's download) is streamed to storage in parts, never read whole.
    def write(bytes:, parent_key: nil, node_key: nil, name: nil, on_conflict: nil, size: nil, sha256: nil)
      size ||= bytes.bytesize
      upload, = reserve(size: size, parent_key: parent_key, node_key: node_key, name: name,
                        on_conflict: on_conflict, multipart: false)
      unless size.zero?
        storage = Disk::Storage.current
        bytes.respond_to?(:path) ? storage.put_file(upload.storage_key, bytes.path) : storage.put_bytes(upload.storage_key, bytes)
      end
      upload.update!(state: Disk::Upload::STATE_COMPLETING, sha256: sha256 || Digest::SHA256.hexdigest(bytes))
      self.class.finish!(upload)
    rescue StandardError
      self.class.abort!(upload) if upload&.reload&.active?
      raise
    end

    # Cancel: release the reservation and the stored parts.
    def abort(upload)
      self.class.abort!(upload, states: [Disk::Upload::STATE_RESERVED])
      return upload if upload.aborted?

      raise Disk::Refused.new("Only an upload still taking parts can be cancelled", status: 409)
    end

    # What storage holds so far, for resuming after a reload.
    def stored_parts(upload)
      return [] unless upload.reserved? && upload.multipart_upload_id

      Disk::Storage.current.parts(upload.storage_key, upload.multipart_upload_id)
    rescue Aws::S3::Errors::NoSuchUpload
      []
    end

    # Validates the parts, completes in storage and commits the version. Used by
    # complete and by the reconcile job for uploads left in completing.
    def self.finish!(upload)
      upload.reload
      return [upload.node, upload.version] if upload.done?
      raise closed(upload, "This upload was cancelled") if upload.aborted?

      storage = Disk::Storage.current
      parts = stored_parts_for_finish(upload, storage)
      outcome = Disk::Node.transaction do
        # Serialised with abort! and with any other finisher on the upload row:
        # only a completing upload is finished, and only once.
        upload.lock!
        next :done if upload.done?
        next Disk::Refused.new("This upload was cancelled", status: 409) unless upload.completing?

        refusal = target_refusal(upload) || seal_refusal(upload)
        next refusal if refusal

        if parts == :empty
          storage.put_empty(upload.storage_key)
        elsif parts
          storage.complete_multipart(upload.storage_key, upload.multipart_upload_id, parts)
        end
        commit!(upload)
      end
      return [upload.node, upload.version] if outcome == :done
      return outcome unless outcome.is_a?(Disk::Refused)

      abort!(upload, states: [Disk::Upload::STATE_COMPLETING])
      raise outcome
    end

    # Releases the reservation and the stored bytes, under a lock on the
    # upload row, only from one of `states`: a cancel or the expiry job abort
    # a reserved upload, a failed completion a completing one, never a done one.
    def self.abort!(upload, states: Disk::Upload::ACTIVE_STATES)
      released = upload.with_lock do
        next false unless states.include?(upload.state)

        Disk::Quota.move!(upload.organization_id, reserved: -upload.declared_bytes)
        upload.update!(state: Disk::Upload::STATE_ABORTED)
      end
      return upload unless released

      storage = Disk::Storage.current
      storage.abort_multipart(upload.storage_key, upload.multipart_upload_id) if upload.multipart_upload_id
      storage.delete([upload.storage_key]) # an earlier try may have completed it in storage
      upload
    end

    # The 409 for an upload that can take no more parts or completion:
    # epoch_changed with current_epoch when it was sealed under a key the
    # scope has since rotated away from (the commit refused and aborted it),
    # upload_closed otherwise. Either way the client starts a new upload.
    def self.closed(upload, message)
      scope = upload.sealed? && (upload.node || upload.parent)&.seal_scope_node_id
      epoch = scope && Disk::Node.where(id: scope).pick(:scope_epoch)
      if epoch && epoch != upload.key_epoch
        return Disk::Refused.new("This folder's key changed. Start the upload again.", status: 409,
                                 code: Disk::Sealing::EPOCH_CHANGED, current_epoch: epoch)
      end

      Disk::Refused.new(message, status: 409, code: Disk::Upload::CLOSED)
    end

    # nil when the target is still there and writable by the uploader.
    def self.target_refusal(upload)
      target = upload.node_id ? upload.node : upload.parent
      if target.nil? || target.trashed? || !Disk::Access.scope_for(upload.membership).exists?(id: target.id)
        return Disk::Refused.new("The folder or file this upload was for is gone", status: 404)
      end
      return if Disk::Access.allows?(upload.membership, target, Disk::ROLE_EDIT)

      Disk::Refused.new("You need edit access for this", status: 403)
    end

    # The epoch rule at the commit point (6.7): an upload reserved under an
    # older epoch, or into a scope waiting for rotation, is aborted.
    def self.seal_refusal(upload)
      (upload.node || upload.parent).write_refusal(upload.membership, upload.key_epoch) if upload.sealed?
    end

    # The parts to complete, :empty for a zero-byte file, or nil when storage
    # already completed it on an earlier try. Refuses (and aborts) on parts the
    # API never issued or sizes that do not add up.
    def self.stored_parts_for_finish(upload, storage)
      unless upload.multipart_upload_id
        return :empty if upload.declared_bytes.zero?
        return if storage.size(upload.storage_key) == upload.declared_bytes # written by #write

        abort!(upload)
        raise Disk::Refused, "The file didn't finish saving. Try again."
      end

      parts = storage.parts(upload.storage_key, upload.multipart_upload_id)
      issued = upload.parts.pluck(:number).to_set
      problem = if parts.empty? then "No parts have been uploaded"
      elsif (stray = parts.map(&:number).reject { |n| issued.include?(n) }).any?
        "Part #{stray.first} was not issued for this upload"
      elsif (odd = parts.sort_by(&:number)[0...-1].find { |p| p.size != upload.part_bytes })
        # R2 refuses unequal parts, so every store is held to it.
        "Part #{odd.number} is #{odd.size} bytes; every part but the last must be #{upload.part_bytes}"
      elsif (sum = parts.sum(&:size)) != upload.declared_bytes
        "The parts add up to #{sum} bytes, not the #{upload.declared_bytes} declared"
      end
      return parts unless problem

      abort!(upload)
      raise Disk::Refused, problem
    rescue Aws::S3::Errors::NoSuchUpload
      return if storage.size(upload.storage_key) == upload.declared_bytes

      abort!(upload)
      raise Disk::Refused, "This upload has ended. Start it again."
    end

    def self.commit!(upload)
      m = upload.membership
      node = upload.node || new_file(upload)
      version = node.add_version!(author: m, key: upload.version_key, storage_key: upload.storage_key,
                                  size_bytes: upload.declared_bytes, chunk_bytes: upload.chunk_bytes,
                                  sha256: upload.sha256, key_epoch: upload.key_epoch,
                                  wrapped_key: upload.wrapped_key, manifest_ciphertext: upload.manifest_ciphertext)
      Disk::Quota.move!(upload.organization_id, reserved: -upload.declared_bytes, used: upload.declared_bytes)
      action = upload.node_id ? Disk::Event::ACTION_VERSION_ADDED : Disk::Event::ACTION_UPLOADED
      Disk::Event.record!(action, actor: m, node: node, name: node.name, version: version.number)
      upload.update!(state: Disk::Upload::STATE_DONE, node: node)
      [node, version]
    end

    # A name taken since the reservation keeps both rather than failing a finished upload.
    def self.new_file(upload)
      parent = upload.parent
      node = Disk::Node.new(key: upload.node_key, organization_id: parent.organization_id, share_id: parent.share_id,
                            custodian_membership_id: parent.custodian_membership_id, parent: parent,
                            kind: Disk::Node::KIND_FILE, created_by: upload.membership)
      node.pending_until = Disk::Upload::TTL.from_now if upload.staged?
      if upload.sealed?
        node.assign_attributes(sealed: true, metadata_ciphertext: upload.intended_metadata_ciphertext,
                               key_epoch: upload.key_epoch, seal_scope_node_id: parent.seal_scope_node_id)
        node.save!
      else
        node.assign_attributes(name: upload.intended_name, mime: mime_for(upload.intended_name))
        node.save_with_unique_name!(keep_both: true)
      end
      node
    end

    # Rack's table lacks markdown, which pages and agents write most.
    MIME_EXTRA = { ".md" => "text/markdown", ".markdown" => "text/markdown" }.freeze

    def self.mime_for(name)
      ext = File.extname(name.to_s).downcase
      MIME_EXTRA[ext] || Rack::Mime.mime_type(ext)
    end

    private

    # [parent folder, existing file or nil]. A clash with a live file asks the
    # caller to choose: on_conflict=replace adds a version to it, keep_both
    # names the new one "a (1).pdf".
    def target_for(parent_key:, node_key:, name:, on_conflict:)
      if node_key.present?
        node = ops.find!(node_key)
        file_writable!(node)
        return [node.parent, node]
      end

      parent = ops.writable_folder!(parent_key)
      return [parent, nil] if parent.sealed?

      probe = Disk::Node.new(kind: Disk::Node::KIND_FILE, name: name.to_s.strip, parent: parent)
      probe.validate
      raise Disk::Refused, "Name #{probe.errors[:name].first}" if probe.errors[:name].any?

      clash = Disk::Node.live.where(parent_id: parent.id).find_by("lower(name) = lower(?)", probe.name)
      return [parent, nil] unless clash

      case on_conflict.to_s
      when "keep_both" then [parent, nil]
      when "replace"
        raise Disk::Refused.new("A folder named \"#{clash.name}\" is in the way", status: 409) unless clash.kind == Disk::Node::KIND_FILE

        file_writable!(clash)
        [parent, clash]
      else raise Disk::Node::NameTaken, clash.name
      end
    end

    def file_writable!(node)
      raise Disk::Refused, "Only a file can take a new version" unless node.kind == Disk::Node::KIND_FILE
      raise Disk::Refused, "This file is in the trash" if node.trashed?

      ops.require_role!(node, Disk::ROLE_EDIT)
    end

    def sealed_attrs(parent, node, chunk_bytes, key_epoch, metadata_ciphertext, size, id)
      raise Disk::Refused, "Only a sealed folder takes sealed uploads" unless parent.sealed?
      raise Disk::Refused, "chunk_bytes must be one of #{Disk::Upload::CHUNK_SIZES.join(', ')}" unless
        Disk::Upload::CHUNK_SIZES.include?(chunk_bytes.to_i)
      raise Disk::Refused, "size_bytes is not a whole number of sealed chunks" unless self.class.sealed_size?(size, chunk_bytes.to_i)

      epoch = Disk::Sealing.epoch!(key_epoch)
      Disk::Node.transaction { (node || parent).write_check!(membership, epoch) } # fail early; completion re-checks
      attrs = { sealed: true, chunk_bytes: chunk_bytes.to_i, key_epoch: epoch }
      return attrs if node

      attrs.merge(node_key: Disk::Sealing.proposed_id!(id, Disk::Node, taken: Disk::Upload.active.exists?(node_key: id.to_s)),
                  intended_metadata_ciphertext: Disk::Sealing.bytes!(metadata_ciphertext, "metadata_ciphertext"))
    end

    # A stored sealed size (6.6): chunks of chunk_bytes + 16, the last at least
    # 16 bytes (an empty file is one 16-byte chunk).
    def self.sealed_size?(size, chunk_bytes)
      c = chunk_bytes + 16
      chunks = (size.to_f / c).ceil
      chunks.positive? && size - ((chunks - 1) * c) >= 16
    end

    public

    # A server-side copy of a sealed version under a reservation (6.8): a copy
    # into parent (a new file) or onto node (restoring an old version). The
    # client gets the new ids from the upload, seals wrapped_key,
    # manifest_ciphertext and, for a new file, metadata_ciphertext to them under
    # key_epoch, and completes it like any upload. Never completed, it is
    # released by the expiry job with its object.
    def reserve_copy(version, parent:, node: nil)
      storage = Disk::Storage.current
      upload = Disk::Upload.transaction do
        (node || parent).write_check!(membership)
        epoch = Disk::Node.where(id: parent.seal_scope_node_id).pick(:scope_epoch)
        Disk::Quota.check!(parent.organization_id, version.size_bytes)
        Disk::Quota.move!(parent.organization_id, reserved: version.size_bytes)
        Disk::Upload.create!(
          organization_id: parent.organization_id, membership: membership, parent: parent, node: node,
          node_key: node&.key || "#{Disk::Node.key_prefix}_#{Nanoid.generate(size: 21)}",
          version_key: "#{Disk::Version.key_prefix}_#{Nanoid.generate(size: 21)}",
          storage_key: Disk::Storage.new_key(membership.organization), declared_bytes: version.size_bytes,
          part_bytes: Disk::Upload.part_bytes_for(version.size_bytes), sealed: true, chunk_bytes: version.chunk_bytes,
          key_epoch: epoch, expires_at: Disk::Upload::TTL.from_now
        )
      end
      storage.copy(version.storage_key, upload.storage_key, version.size_bytes)
      upload
    rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError
      self.class.abort!(upload) if upload
      raise
    end

    private

    def start!(size, parent, node, idempotency_key, attrs, multipart: true)
      storage = Disk::Storage.current
      storage_key = Disk::Storage.new_key(membership.organization)
      multipart_id = nil
      Disk::Upload.transaction do
        Disk::Quota.check!(parent.organization_id, size)
        Disk::Quota.move!(parent.organization_id, reserved: size)
        multipart_id = storage.create_multipart(storage_key) if multipart && size.positive?
        Disk::Upload.create!(
          organization_id: parent.organization_id, membership: membership, parent: parent, node: node,
          node_key: node&.key || "#{Disk::Node.key_prefix}_#{Nanoid.generate(size: 21)}",
          version_key: "#{Disk::Version.key_prefix}_#{Nanoid.generate(size: 21)}",
          storage_key: storage_key, multipart_upload_id: multipart_id, declared_bytes: size,
          part_bytes: Disk::Upload.part_bytes_for(size), idempotency_key: idempotency_key,
          expires_at: Disk::Upload::TTL.from_now, **attrs # a sealed new file's attrs carry its proposed node_key
        )
      end
    rescue StandardError
      storage.abort_multipart(storage_key, multipart_id) if multipart_id
      raise
    end
  end
end
