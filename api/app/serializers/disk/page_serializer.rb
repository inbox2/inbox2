module Disk
  # A page's stored state. ydoc (base64) is the Yjs state the editor loads;
  # markdown is what it renders to, for export and search. A sealed page
  # (build guide 6.10) carries sealed_snapshot with the epoch and seq it
  # covers, the stored updates above it, and update_seq, the newest.
  class PageSerializer
    include Alba::Resource

    attributes :revision, :markdown, :updated_at

    attribute :node_id do |p|
      p.node.key
    end

    attribute :sealed do |p|
      p.node.sealed?
    end

    attribute :ydoc do |p|
      p.ydoc && Base64.strict_encode64(p.ydoc)
    end

    attribute :sealed_snapshot do |p|
      p.sealed_snapshot && Base64.strict_encode64(p.sealed_snapshot)
    end

    attribute :update_seq do |p|
      p.node.sealed? ? p.update_seq : nil
    end

    attributes :snapshot_epoch, :snapshot_seq

    attribute :updates do |p|
      next nil unless p.node.sealed?

      Disk::PageUpdateSerializer.new(p.updates.where("seq > ?", p.snapshot_seq.to_i).order(:seq)).to_h
    end
  end
end
