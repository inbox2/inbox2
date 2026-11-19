module Disk
  # Sealed scopes (build guide 6.2, 6.7): opening one, its key holders,
  # rotation and transfer, and the checks on what sealing clients send. The
  # server never opens a key or a ciphertext; it stores what the client sealed
  # and decides, under a row lock on the scope root, who holds what.
  module Sealing
    ROTATION_REQUIRED = "rotation_required".freeze
    EPOCH_CHANGED = "epoch_changed".freeze
    # A grant inside a scope: the client offers "Move to a new sealed share".
    SEALED_WHOLE = "disk_sealed_whole".freeze
    # Ordinary removal on a sealed scope: removing a holder goes through rotate.
    USE_ROTATE = "disk_use_rotate".freeze
    NO_IDENTITY_KEY = "disk_no_identity_key".freeze
    # Moving or copying across a seal boundary without the sealing client's fields.
    CROSS_SEAL = "disk_cross_seal".freeze
    ID_TAKEN = "disk_id_taken".freeze

    ENVELOPE_MIN = 41 # 0x01 || nonce (24) || tag (16), build guide 6.3
    SHORT_ID = /\A[A-Za-z0-9_-]{21}\z/

    module_function

    # A client-proposed public id for a sealed create (6.5): the model's
    # prefix and 21 nanoid characters, not in use. 409 on a collision.
    def proposed_id!(value, model, taken: false)
      prefix = "#{model.key_prefix}_"
      id = value.to_s
      unless id.start_with?(prefix) && id.delete_prefix(prefix).match?(SHORT_ID)
        raise Disk::Refused, "id must be #{prefix} followed by 21 characters from the nanoid alphabet"
      end
      raise Disk::Refused.new("That id is taken; pick another", status: 409, code: ID_TAKEN) if taken || model.exists?(key: id)

      id
    end

    # Decodes a base64 field. An envelope (6.3) starts with 0x01 and is at
    # least 41 bytes; anything else must be exactly `size` bytes when given.
    def bytes!(value, field, size: nil)
      raw = Base64.strict_decode64(value.to_s)
      ok = size ? raw.bytesize == size : raw.bytesize >= ENVELOPE_MIN && raw.getbyte(0) == 1
      ok ? raw : raise(ArgumentError)
    rescue ArgumentError
      raise Disk::Refused, size ? "#{field} must be #{size} bytes in base64" : "#{field} must be a sealed envelope in base64"
    end

    def epoch!(value, field = "key_epoch")
      epoch = Integer(value.to_s, exception: false)
      epoch&.positive? ? epoch : raise(Disk::Refused, "#{field} must be a positive whole number")
    end

    def entitled!(organization)
      return if organization.e2ee_entitled?

      raise Disk::Refused.new("Sealing is not included in this organization's plan", status: 403)
    end

    # The X25519 identity public key a scope key is sealed to, or nil.
    def public_key(membership)
      membership.agent? ? nil : UserKey.find_by(user_id: membership.user_id)&.public_key
    end

    def identity!(membership)
      return if public_key(membership)

      raise Disk::Refused.new("This person has no encryption key yet, so they can't hold a sealed folder's key",
                              code: NO_IDENTITY_KEY)
    end

    # Everyone with a role that makes them a key holder (6.2), any status:
    # a sealed share's members, or a sealed C:\ folder's custodian and grantees.
    def role_ids(root)
      return Disk::ShareMembership.where(share_id: root.share_id).pluck(:membership_id) if root.share_id

      [root.custodian_membership_id] + Disk::Grant.where(node_id: root.id).pluck(:membership_id)
    end

    # The key holders: role holders whose membership is active.
    def holder_ids(root) = Membership.where(id: role_ids(root), status: Membership::STATUS_ACTIVE).pluck(:id)

    # Makes root (saved, inside the caller's transaction) a scope at epoch 1
    # with its creator's key grant.
    def open_scope!(root, creator, sealed_key)
      identity!(creator)
      root.update!(sealed: true, seal_scope_node_id: root.id, scope_epoch: 1)
      Disk::ScopeEpoch.create!(organization_id: root.organization_id, scope_node: root, epoch: 1, created_by: creator)
      grant_key!(root, creator, creator, sealed_key, 1)
    end

    def grant_key!(root, target, by, sealed_key, epoch)
      grant = Disk::KeyGrant.find_or_initialize_by(scope_node_id: root.id, membership_id: target.id, epoch: epoch)
      grant.update!(organization_id: root.organization_id, granted_by: by,
                    sealed_key: bytes!(sealed_key, "sealed_key", size: Disk::KeyGrant::SEALED_KEY_BYTES))
      grant
    end

    # Gives target a role on the scope together with the current key (6.7):
    # the block makes the role, inside the transaction that holds the scope
    # lock. sealed_key may be left out only when target already holds the
    # current epoch's key (a role change).
    def add_holder!(root, actor:, target:, sealed_key:, epoch:)
      raise Disk::Refused, "Agents never hold sealed keys" if target.agent?

      Disk::Node.transaction do
        root.write_check!(actor, epoch.nil? ? nil : epoch!(epoch, "epoch")) # locks root
        current = root.reload.scope_epoch
        held = Disk::KeyGrant.exists?(scope_node_id: root.id, membership_id: target.disk_ids, epoch: current)
        unless held && sealed_key.blank?
          raise Disk::Refused, "A sealed folder's role needs its key: send sealed_key and epoch" if sealed_key.blank? || epoch.nil?

          identity!(target)
          grant_key!(root, target, actor, sealed_key, current)
        end
        yield
      end
    end

    # POST /scopes/:id/rotate (6.7). One transaction under the scope lock:
    # epoch must be current + 1 and grants must cover exactly the key holders
    # who stay. Removes the roles and every key grant of the removed, stores
    # the new epoch and its grants and clears rotation_due.
    def rotate!(root, actor:, remove:, epoch:, previous_key_wrapped:, grants:)
      Disk::Node.transaction do
        root.lock!
        unless Disk::KeyGrant.exists?(scope_node_id: root.id, membership_id: actor.disk_ids, epoch: root.scope_epoch)
          raise Disk::Refused.new("You hold no key for this sealed folder", status: 403)
        end
        epoch = epoch!(epoch, "epoch")
        unless epoch == root.scope_epoch + 1
          raise Disk::Refused.new("This folder's key changed. Try again.", status: 409,
                                                                              code: EPOCH_CHANGED, current_epoch: root.scope_epoch)
        end

        # People are looked up in the acting member's (team) org and among this
        # folder's own holders, not in the folder's org: a C:\ folder lives in its
        # custodian's personal org while its grantees belong to a team org
        # (Codex review of f2791d0c).
        people = actor.organization.memberships.or(Membership.where(id: role_ids(root)))
        removing = members!(people, Array(remove))
        given = Array(grants).map { |g| g.respond_to?(:to_unsafe_h) ? g.to_unsafe_h : g.to_h }.map(&:with_indifferent_access)
        givers = members!(people, given.map { |g| g[:membership_id] })
        raise Disk::Refused, "Each person can have one grant" if givers.uniq.size != givers.size
        if (stray = removing.map(&:id) - role_ids(root)).any?
          raise Disk::Refused.new("Not a key holder here", not_holders: removing.select { |m| stray.include?(m.id) }.map(&:key))
        end
        raise Disk::Refused, "You can't remove this person from their own C:\\ folder" if removing.any? { |m| m.custodian_of?(root) }

        remaining = holder_ids(root) - removing.map(&:id)
        missing = remaining - givers.map(&:id)
        extra = givers.map(&:id) - remaining
        if missing.any? || extra.any?
          keys = Membership.where(id: missing + extra).pluck(:id, :key).to_h
          raise Disk::Refused.new("grants must cover exactly the key holders who stay",
                                  missing: missing.map { |id| keys[id] }, extra: extra.map { |id| keys[id] })
        end

        ids = removing.map(&:id)
        if root.share_id
          Disk::ShareMembership.where(share_id: root.share_id, membership_id: ids).delete_all
        else
          Disk::Grant.where(node_id: root.id, membership_id: ids).delete_all
        end
        Disk::KeyGrant.where(scope_node_id: root.id, membership_id: ids).delete_all
        Disk::ScopeEpoch.create!(organization_id: root.organization_id, scope_node: root, epoch: epoch, created_by: actor,
                                 previous_key_wrapped: bytes!(previous_key_wrapped, "previous_key_wrapped"))
        given.zip(givers).each { |g, m| grant_key!(root, m, actor, g[:sealed_key], epoch) }
        root.update!(scope_epoch: epoch, rotation_due: false)
        Disk::Event.record!(Disk::Event::ACTION_KEY_ROTATED, actor: actor, node: root, epoch: epoch,
                                                             removed: removing.map(&:key))
      end
      root
    end

    def members!(scope, keys)
      keys = keys.map(&:to_s)
      found = scope.where(key: keys).index_by(&:key)
      unknown = keys - found.keys
      raise Disk::Refused.new("Unknown members", unknown: unknown) if unknown.any?

      keys.map { |k| found[k] }
    end
  end
end
