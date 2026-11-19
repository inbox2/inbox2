module Disk
  # Folder and node operations for one acting member. Shared by the single and
  # bulk endpoints so per-item rules cannot drift. Every lookup goes through
  # Disk::Access.scope_for; refusals raise Disk::Refused.
  class NodeOps
    # What the last move took away: { links:, grants:, agent_grants: }.
    Revoked = Struct.new(:links, :grants, :agent_grants, keyword_init: true)

    attr_reader :membership, :revoked

    def initialize(membership)
      @membership = membership
    end

    def visible = Disk::Access.scope_for(membership)

    def find!(key)
      visible.find_by(key: Disk::Node.key_for(key)) || raise(Disk::Refused.new("Not found", status: 404))
    end

    def require_role!(node, role)
      return if Disk::Access.allows?(membership, node, role)

      raise Disk::Refused.new("You need #{role} access for this", status: 403)
    end

    # A new folder, or a new empty page (in a folder or under another page).
    # seal: the sealing client's fields for a sealed create (build guide 6.5):
    # { id, metadata_ciphertext, key_epoch } inside a sealed folder, plus
    # sealed_key (the creator's key grant, epoch 1) for a new sealed folder on
    # C:\. staged: a page made to replace one across a seal boundary (6.8).
    def create_folder(parent_key:, name:, keep_both: false, kind: Disk::Node::KIND_FOLDER, seal: nil, staged: false)
      parent = writable_folder!(parent_key, child_kind: kind)
      raise Disk::Refused, "Only pages are staged" if staged && kind != Disk::Node::KIND_PAGE
      return create_sealed(parent, kind, seal, staged) if seal || parent.sealed?

      now = Time.current
      node = Disk::Node.new(organization_id: parent.organization_id, share_id: parent.share_id,
                            custodian_membership_id: parent.custodian_membership_id, parent: parent,
                            kind: kind, name: name, created_by: membership,
                            modified_by: membership, content_modified_at: now,
                            pending_until: staged ? Disk::Upload::TTL.from_now : nil)
      Disk::Node.transaction do
        node.save_with_unique_name!(keep_both: keep_both)
        Disk::Page.for(node) if node.page?
      end
      Disk::Event.record!(Disk::Event::ACTION_CREATED, actor: membership, node: node, name: node.name)
      node
    end

    def create_sealed(parent, kind, seal, staged)
      raise Disk::Refused, "Sealed #{kind}s are made by the sealing client" unless seal

      meta = Disk::Sealing.bytes!(seal[:metadata_ciphertext], "metadata_ciphertext")
      epoch = Disk::Sealing.epoch!(seal[:key_epoch])
      now = Time.current
      node = Disk::Node.new(key: Disk::Sealing.proposed_id!(seal[:id], Disk::Node), organization_id: parent.organization_id,
                            share_id: parent.share_id, custodian_membership_id: parent.custodian_membership_id,
                            parent: parent, kind: kind, sealed: true, metadata_ciphertext: meta, key_epoch: epoch,
                            created_by: membership, modified_by: membership, content_modified_at: now,
                            pending_until: staged ? Disk::Upload::TTL.from_now : nil)
      Disk::Node.transaction do
        if parent.sealed?
          parent.write_check!(membership, epoch)
          node.seal_scope_node_id = parent.seal_scope_node_id
          node.save!
        else
          new_scope_root!(parent, node, seal)
        end
        Disk::Page.for(node) if node.page?
      end
      Disk::Event.record!(Disk::Event::ACTION_CREATED, actor: membership, node: node, sealed: true)
      node
    end

    # A sealed folder on the creator's own C:\ (6.2): never inside a share or
    # another scope, epoch 1, the creator's key grant in the same transaction.
    def new_scope_root!(parent, node, seal)
      raise Disk::Refused, "Sealed folders inside a share are not offered; create a sealed share" unless parent.on_c_drive?
      raise Disk::Refused, "Only folders start a sealed scope" unless node.folder?
      raise Disk::Refused.new("Sealed folders are made on your own C:\\", status: 403) unless membership.custodian_of?(parent)
      raise Disk::Refused, "A new sealed folder starts at key_epoch 1" unless node.key_epoch == 1

      Disk::Sealing.entitled!(parent.organization)
      node.save!
      # The key grant goes to the custodian (the personal membership), so it opens from every team.
      Disk::Sealing.open_scope!(node, membership.as_holder(parent), seal[:sealed_key])
    end

    # New sealed metadata (a sealed rename) under the scope's current epoch.
    def rename_sealed(node, metadata_ciphertext:, key_epoch:)
      require_role!(node, Disk::ROLE_EDIT)
      raise Disk::Refused, "A drive's top folder has no name of its own" if node.root?
      raise Disk::Refused, "This item is not sealed" unless node.sealed?

      meta = Disk::Sealing.bytes!(metadata_ciphertext, "metadata_ciphertext")
      epoch = Disk::Sealing.epoch!(key_epoch)
      Disk::Node.transaction do
        node.write_check!(membership, epoch)
        node.update!(metadata_ciphertext: meta, key_epoch: epoch, modified_by: membership, content_modified_at: Time.current)
      end
      Disk::Event.record!(Disk::Event::ACTION_RENAMED, actor: membership, node: node)
      node
    end

    def rename(node, name, keep_both: false)
      require_role!(node, Disk::ROLE_EDIT)
      raise Disk::Refused, "A drive's top folder has no name of its own" if node.root?
      raise Disk::Refused, "Sealed names are changed by the sealing client" if node.sealed?

      from = node.name
      node.assign_attributes(name: name, modified_by: membership, content_modified_at: Time.current)
      node.save_with_unique_name!(keep_both: keep_both)
      Disk::Event.record!(Disk::Event::ACTION_RENAMED, actor: membership, node: node, from: from, to: node.name)
      node
    end

    def star(node, starred)
      if starred
        Disk::Star.find_or_create_by!(organization_id: node.organization_id, node: node, membership: membership.as_holder(node))
      else
        Disk::Star.where(node: node, membership_id: membership.disk_ids).delete_all
      end
      node
    end

    # rewrap: for a move into another sealed scope (6.8), the sealing client's
    # { key_epoch, nodes: [{ id, metadata_ciphertext }], versions: [{ id,
    # wrapped_key }], pages: [{ id, sealed_snapshot, seq }] } for every node,
    # version and saved page in the subtree.
    def move(node, target_key:, keep_both: false, rewrap: nil)
      movable!(node)
      target = writable_folder!(target_key, child_kind: node.kind)
      raise Disk::Refused, "A folder can't be moved into itself" if target.path.any? { |n| n.id == node.id }
      @revoked = Revoked.new(links: [], grants: [], agent_grants: [])
      if node.sealed? && target.sealed? && node.seal_scope_node_id != target.seal_scope_node_id
        return move_across_scopes(node, target, rewrap)
      end
      return node if target.id == node.parent_id

      from = node.parent
      crossing = target.share_id != node.share_id || target.custodian_membership_id != node.custodian_membership_id
      seal_boundary!(node, target, crossing)
      Disk::Node.transaction do
        target.write_check!(membership) if target.sealed?
        revoke_reach!(node) if crossing
        rehome!(node, target)
        node.assign_attributes(parent: target, share_id: target.share_id,
                               custodian_membership_id: target.custodian_membership_id)
        node.save_with_unique_name!(keep_both: keep_both)
        Disk::Node.subtree(node.id).where.not(id: node.id)
          .update_all(share_id: target.share_id, custodian_membership_id: target.custodian_membership_id)
        Disk::Node.add_size!(from, -node.size_bytes)
        Disk::Node.add_size!(target, node.size_bytes)
      end
      moved_event(node, from, target)
    end

    # Sealed scope to sealed scope (6.8): every node gets metadata and every
    # version a wrapped key under the target's current epoch, saved pages a
    # snapshot; objects stay. Links and grants on the moved items go. A sealed
    # C:\ folder moved in stops being a scope root and loses its key grants.
    def move_across_scopes(node, target, rewrap)
      unless rewrap
        raise Disk::Refused.new("Moving into another sealed folder needs the sealing client", code: Disk::Sealing::CROSS_SEAL)
      end

      epoch = Disk::Sealing.epoch!(rewrap[:key_epoch])
      nodes = Disk::Node.subtree(node.id).to_a
      versions = Disk::Version.where(node_id: nodes.map(&:id)).includes(:node).to_a
      pages = Disk::Page.where(node_id: nodes.map(&:id)).where.not(sealed_snapshot: nil).includes(:node).to_a
      metas = rewrap_fields!(rewrap[:nodes], nodes.map(&:key), "nodes") { |e| Disk::Sealing.bytes!(e[:metadata_ciphertext], "metadata_ciphertext") }
      wraps = rewrap_fields!(rewrap[:versions], versions.map(&:key), "versions") { |e| Disk::Sealing.bytes!(e[:wrapped_key], "wrapped_key") }
      snaps = rewrap_fields!(rewrap[:pages], pages.map { |p| p.node.key }, "pages") do |e|
        [Disk::Sealing.bytes!(e[:sealed_snapshot], "sealed_snapshot"), Integer(e[:seq].to_s, exception: false)]
      end
      from = node.parent
      Disk::Node.transaction do
        Disk::Node.lock.where(id: [node.seal_scope_node_id, target.seal_scope_node_id]).order(:id).to_a # one order: no deadlock
        target.write_check!(membership, epoch)
        pages.each do |p|
          p.lock!
          next if snaps[p.node.key][1] == p.update_seq

          raise Disk::Refused.new("A page changed during the move. Try again.", status: 409, page_id: p.node.key, update_seq: p.update_seq)
        end
        revoke_reach!(node)
        if node.scope_root?
          Disk::KeyGrant.where(scope_node_id: node.id).delete_all
          Disk::ScopeEpoch.where(scope_node_id: node.id).delete_all
        end
        rehome!(node, target)
        nodes.each do |n|
          n.update_columns(metadata_ciphertext: metas[n.key], key_epoch: epoch, seal_scope_node_id: target.seal_scope_node_id,
                           share_id: target.share_id, custodian_membership_id: target.custodian_membership_id)
        end
        versions.each { |v| v.update_columns(wrapped_key: wraps[v.key], key_epoch: epoch) }
        pages.each do |p|
          p.update_columns(sealed_snapshot: snaps[p.node.key][0], snapshot_epoch: epoch, snapshot_seq: p.update_seq)
          Disk::PageUpdate.where(node_id: p.node_id).delete_all
        end
        node.reload.update!(parent: target, scope_epoch: nil, rotation_due: false)
        Disk::Node.add_size!(from, -node.size_bytes)
        Disk::Node.add_size!(target, node.size_bytes)
      end
      moved_event(node, from, target)
    end

    # { id => block(entry) } for exactly the expected ids; 422 naming the rest.
    def rewrap_fields!(entries, expected, field)
      entries = Array(entries).map { |e| (e.respond_to?(:to_unsafe_h) ? e.to_unsafe_h : e.to_h).with_indifferent_access }
      got = entries.to_h { |e| [e[:id].to_s, e] }
      missing = expected - got.keys
      extra = got.keys - expected
      if missing.any? || extra.any? || got.size != entries.size
        raise Disk::Refused.new("#{field} must list each moved item once", missing: missing, extra: extra)
      end

      got.transform_values { |e| yield e }
    end

    # A C:\ is its person's own workspace (2026-10-07), so a move between a C:\
    # and a team's share crosses organizations: every row of the subtree that
    # carries the org follows it, and its bytes move between the two quotas.
    # Inside the move's transaction. Nothing to do within one org.
    REHOMED_BY_NODE = %w[disk_versions disk_stars disk_grants disk_agent_grants disk_links disk_pages disk_page_versions
                         disk_page_updates disk_recents].freeze
    def rehome!(node, target)
      return if target.organization_id == node.organization_id

      ids = Disk::Node.subtree(node.id).select(:id)
      bytes = Disk::Version.where(node_id: ids).sum(:size_bytes)
      Disk::Quota.check!(target.organization_id, bytes)
      Disk::Quota.move!(target.organization_id, used: bytes)
      Disk::Quota.move!(node.organization_id, used: -bytes)
      REHOMED_BY_NODE.each { |t| Disk::Node.connection.execute(Disk::Node.sanitize_sql(["UPDATE #{t} SET organization_id = ? WHERE node_id IN (#{ids.to_sql})", target.organization_id])) }
      Disk::KeyGrant.where(scope_node_id: ids).update_all(organization_id: target.organization_id)
      Disk::ScopeEpoch.where(scope_node_id: ids).update_all(organization_id: target.organization_id)
      Disk::Node.where(id: ids).update_all(organization_id: target.organization_id)
      node.organization_id = target.organization_id
    end

    def moved_event(node, from, target)
      Disk::Event.record!(Disk::Event::ACTION_MOVED, actor: membership, node: node,
                                                     from_parent: from.key, to_parent: target.key,
                                                     revoked_links: revoked.links.size,
                                                     revoked_grants: revoked.grants.size + revoked.agent_grants.size)
      node
    end

    # A file or page staged across a seal boundary (6.8) takes source's place in
    # one transaction: the staged node becomes visible, the source is marked
    # switched (invisible) and its links revoked; then its objects are purged.
    # A purge that fails here is finished by Disk::ExpireUploadsJob.
    def switch(source, staged_key:)
      staged = Disk::Node.where(created_by_membership_id: membership.id)
        .where.not(pending_until: nil).find_by(key: Disk::Node.key_for(staged_key))
      raise Disk::Refused.new("Not found", status: 404) unless staged
      raise Disk::Refused, "Only files and pages are switched; recreate folders" unless [Disk::Node::KIND_FILE, Disk::Node::KIND_PAGE].include?(source.kind)
      raise Disk::Refused, "The staged item must be the same kind" unless staged.kind == source.kind
      raise Disk::Refused, "A switch crosses a seal boundary" if staged.sealed? == source.sealed?
      raise Disk::Refused, "This item is in the trash" if source.trashed?
      raise Disk::Refused, "Move its sub-pages first" if source.children.exists?

      require_role!(source, source.sealed? ? Disk::ROLE_MANAGE : Disk::ROLE_EDIT)
      @revoked = Revoked.new(links: [], grants: [], agent_grants: [])
      Disk::Node.transaction do
        staged.write_check!(membership) if staged.sealed?
        source.lock!
        raise Disk::Refused.new("Not found", status: 404) if source.switched_at

        revoke_reach!(source)
        staged.update!(pending_until: nil)
        source.update!(switched_at: Time.current)
        Disk::Node.add_size!(source.parent, -source.size_bytes)
      end
      Disk::Event.record!(Disk::Event::ACTION_SWITCHED, actor: membership, node: staged, source: source.key,
                                                        sealed: staged.sealed?)
      self.class.purge_switched!(source)
      staged
    end

    def self.purge_switched!(node)
      purge!(node)
    rescue ActiveRecord::ActiveRecordError, Aws::Errors::ServiceError => e
      Rails.logger.warn("[Disk] switched #{node.key} not purged yet: #{e.class}")
    end

    # Copies a file or folder. Each file's current version is copied in
    # storage first (older versions stay behind), then the rows and the quota
    # land in one transaction; a refusal deletes the copied objects.
    # replace: a file copied over a live file of the same name becomes that
    # file's new version instead of a second file.
    def copy(node, target_key:, keep_both: false, replace: false)
      require_role!(node, Disk::ROLE_VIEW)
      raise Disk::Refused, "A drive's top folder can't be copied" if node.root?
      return copy_sealed(node, writable_folder!(target_key, child_kind: node.kind)) if node.sealed?

      subtree =Disk::Node.subtree(node.id, skip_trash_roots: true).live
      raise Disk::Refused, "You can't copy a folder with sealed items inside" if subtree.where(sealed: true).exists?

      target = writable_folder!(target_key, child_kind: node.kind)
      if target.sealed?
        raise Disk::Refused.new("Copying into a sealed folder needs the sealing client", code: Disk::Sealing::CROSS_SEAL)
      end
      raise Disk::Refused, "A folder can't be copied into itself" if target.path.any? { |n| n.id == node.id }

      if replace && node.kind == Disk::Node::KIND_FILE && node.current_version
        clash = Disk::Node.live.where(parent_id: target.id).where.not(id: node.id)
          .find_by("lower(name) = lower(?)", node.name)
        return copy_as_version(node, clash) if clash
      end

      versions = Disk::Version.where(id: subtree.select(:current_version_id)).index_by(&:node_id)
      total = versions.values.sum(&:size_bytes)
      Disk::Node.transaction { Disk::Quota.check!(target.organization_id, total) } # refuse before copying anything

      copies = {}
      copy_objects(versions, copies)
      copy = Disk::Node.transaction do
        Disk::Quota.check!(target.organization_id, total)
        Disk::Quota.move!(target.organization_id, used: total)
        top = copy_one(node, target)
        top.save_with_unique_name!(keep_both: keep_both)
        copy_content(node, top, versions, copies)
        top
      end
      Disk::Event.record!(Disk::Event::ACTION_COPIED, actor: membership, node: copy, from: node.key)
      copy
    rescue StandardError
      Disk::Version.delete_objects(copies.values) if copies&.any? && !copy
      raise
    end

    # A sealed file copied into a sealed folder (6.8): the API copies the
    # object under a reserved upload whose new node and version ids the client
    # seals to, and POST /uploads/:id/complete with the re-sealed fields makes
    # the copy visible. An unfinished copy is an upload the expiry job releases.
    # Folders and pages are copied by the client item by item.
    def copy_sealed(node, target)
      unless target.sealed?
        raise Disk::Refused.new("Copying out of a sealed folder needs the sealing client", code: Disk::Sealing::CROSS_SEAL)
      end
      raise Disk::Refused, "The sealing client copies sealed folders and pages item by item" unless node.kind == Disk::Node::KIND_FILE && node.current_version

      Disk::UploadOps.new(membership).reserve_copy(node.current_version, parent: target)
    end

    # Copies node's current version into clash as its newest version.
    def copy_as_version(node, clash)
      raise Disk::Refused.new("A folder named \"#{clash.name}\" is in the way", status: 409) unless clash.kind == Disk::Node::KIND_FILE

      require_role!(clash, Disk::ROLE_EDIT)
      source = node.current_version
      # The new version is clash's, so clash's org pays (C:\ is a personal org, a share a team's).
      Disk::Node.transaction { Disk::Quota.check!(clash.organization_id, source.size_bytes) }
      key = Disk::Storage.new_key(clash.organization)
      Disk::Storage.current.copy(source.storage_key, key, source.size_bytes)
      version = Disk::Node.transaction do
        Disk::Quota.check!(clash.organization_id, source.size_bytes)
        Disk::Quota.move!(clash.organization_id, used: source.size_bytes)
        clash.add_version!(author: membership, storage_key: key, size_bytes: source.size_bytes, sha256: source.sha256)
      end
      Disk::Event.record!(Disk::Event::ACTION_VERSION_ADDED, actor: membership, node: clash, name: clash.name,
                                                             version: version.number, from: node.key)
      clash
    rescue StandardError
      Disk::Version.delete_objects([key]) if key && !version
      raise
    end

    # A new current version made from an older one: a server-side copy of its
    # object. A sealed version answers an upload reservation instead (6.8).
    def restore_version(version)
      node = find!(version.node.key)
      require_role!(node, Disk::ROLE_EDIT)
      raise Disk::Refused, "This file is in the trash" if node.trashed?
      raise Disk::Refused, "This is already the current version" if version.current?
      # Sealed: a copy onto the same node, completed with K_v re-wrapped under the current epoch (6.8).
      return Disk::UploadOps.new(membership).reserve_copy(version, parent: node.parent, node: node) if node.sealed?

      key = Disk::Storage.new_key(membership.organization)
      Disk::Storage.current.copy(version.storage_key, key, version.size_bytes)
      restored = Disk::Node.transaction do
        Disk::Quota.check!(node.organization_id, version.size_bytes)
        Disk::Quota.move!(node.organization_id, used: version.size_bytes)
        node.add_version!(author: membership, storage_key: key, size_bytes: version.size_bytes, sha256: version.sha256)
      end
      Disk::Event.record!(Disk::Event::ACTION_VERSION_RESTORED, actor: membership, node: node, name: node.name,
                                                                from: version.number, version: restored.number)
      restored
    rescue StandardError
      Disk::Version.delete_objects([key]) if key && !restored
      raise
    end

    def trash(node)
      movable!(node)
      now = Time.current
      Disk::Node.transaction do
        node.update!(trashed_at: now, trashed_by: membership, trash_root: true, original_parent_id: node.parent_id)
        Disk::Node.subtree(node.id).where(trashed_at: nil)
          .update_all(trashed_at: now, trashed_by_membership_id: membership.id)
        Disk::Node.add_size!(node.parent, -node.size_bytes)
      end
      Disk::Event.record!(Disk::Event::ACTION_TRASHED, actor: membership, node: node, name: node.name)
      node
    end

    # Puts a deleted item back where it was, or at the top of its drive when its
    # folder is itself in the trash. A name clash on the way back keeps both.
    # Returns [node, restored_to_root].
    def restore(node)
      raise Disk::Refused, "This item is not in the trash" unless node.trash_root?

      require_role!(node, Disk::ROLE_EDIT)
      parent = node.parent
      to_root = parent.trashed?
      if to_root
        parent = visible.find_by(parent_id: nil, share_id: node.share_id,
                                 custodian_membership_id: node.custodian_membership_id) ||
                 raise(Disk::Refused.new("Not found", status: 404))
        unless Disk::Access.allows?(membership, parent, Disk::ROLE_EDIT)
          raise Disk::Refused.new("Its folder is in the trash. Ask someone with edit access to restore it.",
                                  status: 403)
        end
        # A sealed item goes back only inside its own scope (6.2).
        raise Disk::Refused, "Restore its sealed folder first" if node.sealed? && !node.scope_root? && !parent.sealed?
      end
      Disk::Node.transaction do
        node.write_check!(membership) if node.sealed?
        Disk::Node.subtree(node.id, skip_trash_roots: true).where.not(id: node.id)
          .update_all(trashed_at: nil, trashed_by_membership_id: nil)
        node.assign_attributes(parent: parent, trashed_at: nil, trashed_by: nil, trash_root: false,
                               original_parent_id: nil)
        node.save_with_unique_name!(keep_both: true)
        Disk::Node.add_size!(parent, node.size_bytes)
      end
      Disk::Event.record!(Disk::Event::ACTION_RESTORED, actor: membership, node: node, to_root: to_root)
      [node, to_root]
    end

    # A staged node (6.8) is purged straight away by its creator when staging fails.
    # empty_only: refuse when anything is beneath it (the sealing client's move
    # deletes the emptied source this way; whatever arrived since stays in the Trash).
    def purge(node, empty_only: false)
      raise Disk::Refused, "Only items in the trash can be deleted forever" unless node.trash_root? || node.pending?
      if empty_only && Disk::Node.subtree(node.id).where.not(id: node.id).exists?
        raise Disk::Refused.new("#{node.name} is not empty; it stays in the Trash", status: 409)
      end

      require_role!(node, Disk::ROLE_EDIT)
      Disk::Node.add_size!(node.parent, -node.size_bytes) if node.pending?
      self.class.purge!(node, actor: membership)
    end

    # Deletes a trashed item and everything beneath it with every version:
    # the bytes go back to the quota and the objects leave the bucket once the
    # rows are gone. Its size already left the folders above when it was trashed.
    def self.purge!(node, actor: nil)
      Disk::Node.transaction do
        Disk::Event.record!(Disk::Event::ACTION_PURGED, actor: actor, node: node, name: node.name)
        subtree = Disk::Node.subtree(node.id)
        Disk::Version.release!(Disk::Version.where(node_id: subtree.select(:id)))
        # Links first: when one statement cascades to both a link and an event
        # naming it, Postgres trips over the event's link foreign key.
        Disk::Link.where(node_id: subtree.select(:id)).delete_all
        subtree.delete_all
      end
    end

    # Shares a node with a named member at view or edit. On a sealed C:\
    # folder's root the sealing client sends the current key sealed to them
    # (sealed_key, epoch) in the same request (6.7); anywhere else in a scope
    # the answer is "move it into a new sealed share" (SEALED_WHOLE).
    def grant(node, target, role, sealed_key: nil, epoch: nil)
      sealed_grant_target!(node) if node.sealed?
      manageable!(node)
      raise Disk::Refused, "Agents are given access through agent grants" if target.agent?

      grant = node.grants.find_or_initialize_by(membership: target)
      action = grant.new_record? ? Disk::Event::ACTION_GRANTED : Disk::Event::ACTION_GRANT_CHANGED
      grant.assign_attributes(organization_id: node.organization_id, role: role.to_s, granted_by: membership)
      if node.sealed?
        raise Disk::Refused, "This person already holds this folder's key" if target.custodian_of?(node)

        Disk::Sealing.add_holder!(node, actor: membership, target: target, sealed_key: sealed_key, epoch: epoch) { grant.save! }
      else
        grant.save!
      end
      Disk::Event.record!(action, actor: membership, node: node, member: target.key, role: grant.role)
      Disk::ShareNotifier.granted(actor: membership, target: target, node: node, role: grant.role) if
        action == Disk::Event::ACTION_GRANTED
      grant
    end

    def ungrant(node, target)
      raise use_rotate if node.sealed?

      manageable!(node)
      node.grants.find_by!(membership: target).destroy!
      Disk::Event.record!(Disk::Event::ACTION_UNGRANTED, actor: membership, node: node, member: target.key)
    end

    def use_rotate
      Disk::Refused.new("Removing someone from a sealed folder renews its key: use rotate", code: Disk::Sealing::USE_ROTATE)
    end

    # POST /scopes/:id/transfer (6.7): a manager hands the scope's key to
    # another member with manage on a sealed share, or edit on a sealed C:\
    # folder (grants top out at edit; the member who takes the C:\ over on
    # offboarding manages it as its custodian).
    def transfer(root, target, sealed_key:, epoch:)
      require_role!(root, Disk::ROLE_MANAGE)
      raise Disk::Refused, "Agents never hold sealed keys" if target.agent?
      raise Disk::Refused, "This person already holds this folder's key" if target.custodian_of?(root)

      Disk::Sealing.add_holder!(root, actor: membership, target: target, sealed_key: sealed_key, epoch: epoch) do
        if root.share_id
          Disk::ShareMembership.find_or_initialize_by(share_id: root.share_id, membership_id: target.id)
            .update!(organization_id: root.organization_id, role: Disk::ROLE_MANAGE)
        else
          root.grants.find_or_initialize_by(membership: target)
            .update!(organization_id: root.organization_id, role: Disk::ROLE_EDIT, granted_by: membership)
        end
      end
      Disk::Event.record!(Disk::Event::ACTION_KEY_TRANSFERRED, actor: membership, node: root, member: target.key)
      root
    end

    # A public link on an unsealed file or folder. Returns [link, token]; the
    # token is never readable again.
    # seal: a sealed file's link fields from the sealing client (6.9).
    def create_link(node, password: nil, expires_at: nil, hide_download: false, seal: nil)
      manageable!(node)
      unless node.organization.disk_links_enabled
        raise Disk::Refused.new("Public links are turned off for this organization", status: 403)
      end
      raise Disk::Refused, "A drive's top folder can't have a public link" if node.root?
      raise Disk::Refused, "Only files and folders can have public links" if node.page?
      return create_sealed_link(node, seal, link_expiry(expires_at), hide_download) if node.sealed?

      pw = password.to_s
      raise Disk::Refused, "That password is too long" if pw.bytesize > Disk::Link::PASSWORD_MAX_BYTES

      token = Disk::Link.new_token
      link = Disk::Link.new(organization_id: node.organization_id, node: node, created_by: membership,
                            token_digest: Disk::Link.digest(token), expires_at: link_expiry(expires_at),
                            hide_download: ActiveModel::Type::Boolean.new.cast(hide_download) || false)
      link.password = pw.presence
      link.save!
      Disk::Event.record!(Disk::Event::ACTION_LINK_CREATED, actor: membership, node: node, link: link,
                                                            password: link.password?, expires_at: link.expires_at)
      [link, token]
    end

    # A link to one version of a sealed file (6.9): the client proposes the
    # link id and sends the salt, the payload wrapped under the link key and,
    # with a password, the verifier, of which only a SHA-256 is kept. Sealed
    # folders get none (decided 2026-10-03), so wrap_key_sealed stays unused.
    def create_sealed_link(node, seal, expires_at, hide_download)
      raise Disk::Refused, "Sealed folders have no public links; link a single file" unless node.kind == Disk::Node::KIND_FILE

      seal ||= {}
      version = node.versions.find_by(key: seal[:version_id].to_s) ||
                raise(Disk::Refused, "version_id must be one of this file's versions")
      verifier = seal[:password_verifier].presence
      token = Disk::Link.new_token
      link = Disk::Node.transaction do
        # A new link publishes a credential: a write (6.7), so under the scope
        # lock, by a current key holder, and refused while rotation is due. The
        # payload wraps K_v, not the scope key, so no epoch to check (as thumbnails).
        node.write_check!(membership)
        Disk::Link.create!(
          key: Disk::Sealing.proposed_id!(seal[:id], Disk::Link), organization_id: node.organization_id, node: node,
          version: version, created_by: membership, token_digest: Disk::Link.digest(token), expires_at: expires_at,
          hide_download: ActiveModel::Type::Boolean.new.cast(hide_download) || false, kdf_version: Disk::Link::KDF_VERSION,
          kdf_salt: Disk::Sealing.bytes!(seal[:kdf_salt], "kdf_salt", size: Disk::Link::SALT_BYTES),
          wrapped_payload: Disk::Sealing.bytes!(seal[:wrapped_payload], "wrapped_payload"),
          password_verifier_digest: verifier && Disk::Link.verifier_digest(Disk::Sealing.bytes!(verifier, "password_verifier", size: 32))
        )
      end
      Disk::Event.record!(Disk::Event::ACTION_LINK_CREATED, actor: membership, node: node, link: link,
                                                            password: link.password?, expires_at: link.expires_at)
      [link, token]
    end

    # Links on nodes this member can see, by public id.
    def find_link!(key)
      Disk::Link.where(node_id: visible.select(:id)).includes(:node).find_by(key: key.to_s) ||
        raise(Disk::Refused.new("Not found", status: 404))
    end

    def revoke_link(link)
      manageable!(link.node)
      link.update!(revoked_at: Time.current) unless link.revoked?
      Disk::Event.record!(Disk::Event::ACTION_LINK_REVOKED, actor: membership, node: link.node, link: link)
      link
    end

    # Saves an unsealed page snapshot made from base_revision (409 with
    # current_revision when someone saved since) and tells open editors.
    # ydoc nil means the content is only markdown (an agent's write): editors
    # rebuild their document from it (DiskPageChannel "page_replaced").
    def save_page(node, ydoc:, markdown:, base_revision:, restored_from: nil)
      raise Disk::Refused, "This is not a page" unless node.page?

      require_role!(node, Disk::ROLE_EDIT)
      raise Disk::Refused, "This page is in the trash" if node.trashed?
      raise Disk::Refused, "Sealed pages are saved by the sealing client" if node.sealed?
      if [ydoc, markdown].any? { |v| v.to_s.bytesize > Disk::Page::MAX_BYTES }
        raise Disk::Refused.new("This page is too large", status: 413)
      end

      page = Disk::Page.for(node)
      page.save_snapshot!(author: membership, ydoc: ydoc, markdown: markdown, base_revision: base_revision,
                          restored_from: restored_from)
      DiskPageChannel.saved(node, page, membership)
      page
    end

    # A sealed page's snapshot (6.10): the Yjs state sealed under the current
    # epoch, covering every update up to seq. Updates at or below it go.
    def save_sealed_page(node, sealed_snapshot:, epoch:, seq:)
      page = sealed_page!(node)
      snap = Disk::Sealing.bytes!(sealed_snapshot, "sealed_snapshot")
      raise Disk::Refused.new("This page is too large", status: 413) if snap.bytesize > Disk::Page::MAX_BYTES

      page.save_sealed_snapshot!(author: membership, snapshot: snap, epoch: Disk::Sealing.epoch!(epoch, "epoch"),
                                 seq: seq!(seq))
      DiskPageChannel.sealed_snapshot(node, page, membership)
      page
    end

    # One sealed page update at exactly update_seq + 1 under the current epoch
    # (6.10), relayed to the page's editors once it has committed.
    def append_page_update(node, update:, epoch:, seq:)
      page = sealed_page!(node)
      bytes = Disk::Sealing.bytes!(update, "update")
      raise Disk::Refused.new("This change is too large", status: 413) if bytes.bytesize > Disk::Page::MAX_UPDATE_BYTES

      row = page.append_sealed_update!(author: membership, ciphertext: bytes, epoch: Disk::Sealing.epoch!(epoch, "epoch"),
                                       seq: seq!(seq))
      DiskPageChannel.sealed_update(node, row, membership)
      row
    end

    def sealed_page!(node)
      raise Disk::Refused, "This is not a page" unless node.page?
      raise Disk::Refused, "This page is not sealed" unless node.sealed?

      require_role!(node, Disk::ROLE_EDIT)
      raise Disk::Refused, "This page is in the trash" if node.trashed?

      Disk::Page.for(node)
    end

    def seq!(value)
      seq = Integer(value.to_s, exception: false)
      seq && seq >= 0 ? seq : raise(Disk::Refused, "seq must be a whole number")
    end

    # The folder (or, for a page, the parent page) new items go into.
    def writable_folder!(key, child_kind: nil)
      folder = find!(key)
      raise Disk::Refused, "Items can only go into a folder" unless folder.container?
      raise Disk::Refused, "Only pages can go inside a page" if folder.page? && child_kind != Disk::Node::KIND_PAGE
      raise Disk::Refused, "That folder is in the trash" if folder.trashed?

      require_role!(folder, Disk::ROLE_EDIT)
      folder
    end

    private

    def manageable!(node)
      raise Disk::Refused, "This item is in the trash" if node.trashed?

      require_role!(node, Disk::ROLE_MANAGE)
    end

    # A move to another drive or share takes the subtree out of reach of
    # everything that pointed into it from where it was: its public links,
    # people's grants and agents' grants. Fills @revoked.
    def revoke_reach!(node)
      ids = Disk::Node.subtree(node.id).select(:id)
      links = Disk::Link.active.where(node_id: ids)
      grants = Disk::Grant.where(node_id: ids).includes(:node, :membership)
      agent_grants = Disk::AgentGrant.where(node_id: ids).includes(:node, :agent)
      @revoked = Revoked.new(
        links: links.pluck(:key),
        grants: grants.map { |g| { node_id: g.node.key, member_id: g.membership.key } },
        agent_grants: agent_grants.map { |g| { node_id: g.node.key, agent_id: g.agent.key } }
      )
      links.update_all(revoked_at: Time.current)
      grants.delete_all
      agent_grants.delete_all
    end

    def link_expiry(value)
      return nil if value.blank?

      at = value.is_a?(Time) ? value : Time.zone.parse(value.to_s)
      raise Disk::Refused, "expires_at must be a time in the future" unless at&.future?

      at
    rescue ArgumentError
      raise Disk::Refused, "expires_at must be a time in the future"
    end

    def sealed_grant_target!(node)
      return if node.scope_root? && node.on_c_drive?
      raise Disk::Refused, "Add people to a sealed share as its members" if node.scope_root?

      raise Disk::Refused.new("A sealed folder is shared as a whole: move this into a new sealed share to share it",
                              code: Disk::Sealing::SEALED_WHOLE)
    end

    # A scope holds only sealed nodes and no other scope root (6.2). Crossing
    # into or out of a seal is the staged switch, never a move; a sealed C:\
    # folder moves only within its own C:\.
    def seal_boundary!(node, target, crossing)
      cross = Disk::Refused.new("Moving across a seal boundary re-uploads each file: use the sealing client",
                                code: Disk::Sealing::CROSS_SEAL)
      raise cross if target.sealed? && !node.sealed?
      raise cross if node.sealed? && !target.sealed? && !(node.scope_root? && !crossing)
      return unless crossing && !node.sealed? && Disk::Node.subtree(node.id).where(sealed: true).exists?

      raise Disk::Refused, "A sealed folder inside this one stays on C:\\. Move it out first."
    end

    def movable!(node)
      raise Disk::Refused, "A drive's top folder can't be moved or deleted" if node.root?
      raise Disk::Refused, "This item is in the trash" if node.trashed?

      require_role!(node, Disk::ROLE_EDIT)
    end

    def copy_one(source, parent)
      Disk::Node.new(organization_id: parent.organization_id, share_id: parent.share_id,
                     custodian_membership_id: parent.custodian_membership_id, parent: parent,
                     kind: source.kind, name: source.name, mime: source.mime, created_by: membership,
                     modified_by: membership, content_modified_at: Time.current)
    end

    # A page's copy starts its own history at the source's current text.
    def copy_page(source, copy)
      page = Disk::Page.for(source)
      Disk::Page.create!(organization_id: copy.organization_id, node: copy, ydoc: page.ydoc, markdown: page.markdown)
      Disk::Node.add_size!(copy, page.markdown.to_s.bytesize) # sub-pages add theirs as they are copied
    end

    # Fills copies with { source node id => new object key } as each copy lands in storage.
    def copy_objects(versions, copies)
      storage = Disk::Storage.current
      versions.each do |node_id, v|
        key = Disk::Storage.new_key(membership.organization)
        storage.copy(v.storage_key, key, v.size_bytes)
        copies[node_id] = key
      end
    end

    # Each copied file gets version 1 pointing at its copied object; sizes roll up as they land.
    def copy_content(source, copy, versions, copies)
      if (v = versions[source.id])
        copy.add_version!(author: membership, storage_key: copies[source.id], size_bytes: v.size_bytes, sha256: v.sha256)
      end
      copy_page(source, copy) if source.page?
      source.children.live.find_each do |child|
        child_copy = copy_one(child, copy)
        child_copy.save!
        copy_content(child, child_copy, versions, copies)
      end
    end
  end
end
