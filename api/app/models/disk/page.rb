module Disk
  # The content of a page node (spec F6). Unsealed: the editor's Yjs state and
  # the markdown it renders to. Sealed (build guide 6.10): no markdown, a
  # sealed_snapshot covering updates up to snapshot_seq under snapshot_epoch,
  # and stored updates (Disk::PageUpdate) above it, update_seq the newest.
  # revision goes up on every save, so a writer that saved from an older
  # revision is told to merge first.
  class Page < ApplicationRecord
    MAX_BYTES = 5.megabytes # each of ydoc and markdown, or a sealed snapshot
    MAX_UPDATE_BYTES = 1.megabyte # one sealed update
    # Saves by one person within this window refine one history entry.
    HISTORY_WINDOW = 10.minutes

    belongs_to :organization
    belongs_to :node, class_name: "Disk::Node"

    def self.for(node) = find_or_create_by!(node_id: node.id) { |p| p.organization_id = node.organization_id }

    def versions = Disk::PageVersion.where(node_id: node_id)

    # Saves a snapshot made from base_revision; 409 with the current revision
    # if someone saved in between. Updates the node's size and modified
    # fields and the page history, inside one transaction. restored_from names
    # the history revision the editor brought back, which always starts a new entry.
    def save_snapshot!(author:, ydoc:, markdown:, base_revision:, restored_from: nil)
      Disk::Node.transaction do
        lock!
        unless base_revision == revision
          raise Disk::Refused.new("This page changed since you opened it. Save again.",
                                  status: 409, current_revision: revision)
        end

        # A page's size is its markdown plus its sub-pages', like a folder's.
        delta = markdown.to_s.bytesize - self.markdown.to_s.bytesize
        update!(ydoc: ydoc, markdown: markdown, revision: revision + 1)
        node.update!(modified_by: author, content_modified_at: Time.current)
        Disk::Node.add_size!(node, delta)
        record_history!(author, restored_from)
      end
    end

    def updates = Disk::PageUpdate.where(node_id: node_id)

    # A sealed snapshot (6.10) under the scope lock: the current epoch, seq no
    # older than the stored snapshot's and no newer than update_seq. The
    # page's size is the snapshot's length.
    def save_sealed_snapshot!(author:, snapshot:, epoch:, seq:)
      Disk::Node.transaction do
        node.write_check!(author, epoch)
        lock!
        unless seq.between?(snapshot_seq.to_i, update_seq)
          raise Disk::Refused.new("This page changed. Try again.", status: 409,
                                                                                               **sealed_state)
        end

        delta = snapshot.bytesize - sealed_snapshot.to_s.bytesize
        update!(sealed_snapshot: snapshot, snapshot_epoch: epoch, snapshot_seq: seq, revision: revision + 1)
        updates.where(seq: ..seq).delete_all
        node.update!(modified_by: author, content_modified_at: Time.current)
        Disk::Node.add_size!(node, delta)
        record_history!(author, nil)
      end
    end

    # One sealed update at exactly update_seq + 1 under the current epoch,
    # checked and stored under the scope lock; anything else is 409 with the
    # current values and reaches nobody.
    def append_sealed_update!(author:, ciphertext:, epoch:, seq:)
      Disk::Node.transaction do
        node.write_check!(author, epoch)
        lock!
        raise Disk::Refused.new("This page changed. Try again.", status: 409, **sealed_state) unless seq == update_seq + 1

        update!(update_seq: seq)
        Disk::PageUpdate.create!(organization_id: organization_id, node_id: node_id, epoch: epoch, seq: seq,
                                 ciphertext: ciphertext)
      end
    end

    def sealed_state
      { update_seq: update_seq, snapshot_seq: snapshot_seq, current_epoch: Disk::Node.where(id: node.seal_scope_node_id).pick(:scope_epoch) }
    end

    private

    def record_history!(author, restored_from)
      last = versions.order(revision: :desc).first
      if !restored_from && last && last.author_membership_id == author.id && last.created_at > HISTORY_WINDOW.ago
        return last.update!(revision: revision, **history_content)
      end

      versions.create!(organization_id: organization_id, revision: revision, author: author, **history_content)
      if restored_from
        Disk::Event.record!(Disk::Event::ACTION_PAGE_RESTORED, actor: author, node: node, revision: revision,
                                                               from: restored_from)
      else
        Disk::Event.record!(Disk::Event::ACTION_PAGE_SAVED, actor: author, node: node, revision: revision)
      end
    end

    # Sealed pages have history only as snapshots.
    def history_content
      return { ydoc: ydoc, markdown: markdown } unless node.sealed?

      { sealed_snapshot: sealed_snapshot, snapshot_epoch: snapshot_epoch, snapshot_seq: snapshot_seq }
    end
  end
end
