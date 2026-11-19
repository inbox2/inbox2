module Disk
  # A sealed scope as one member sees it (build guide 6.7): the current epoch,
  # whether a rotation is due, this member's key grants, the epoch chain, the
  # key holders and, for managers, the live file links inside it.
  # params: membership, manager (boolean).
  class ScopeSerializer
    include Alba::Resource

    b64 = ->(bytes) { bytes && Base64.strict_encode64(bytes) }

    attribute :id, &:key
    attribute :epoch, &:scope_epoch
    attributes :rotation_due

    # This member's newest key grant; null when they hold none.
    attribute :grant do |root|
      g = Disk::KeyGrant.where(scope_node_id: root.id, membership_id: params[:membership].disk_ids).order(epoch: :desc).first
      g && { epoch: g.epoch, sealed_key: b64.call(g.sealed_key) }
    end

    # Every key grant this member holds here, newest first.
    attribute :grants do |root|
      Disk::KeyGrant.where(scope_node_id: root.id, membership_id: params[:membership].disk_ids).order(epoch: :desc)
        .map { |g| { epoch: g.epoch, sealed_key: b64.call(g.sealed_key) } }
    end

    # Epochs 2 and up: each wraps the key of the epoch before it.
    attribute :epochs do |root|
      Disk::ScopeEpoch.where(scope_node_id: root.id).where.not(previous_key_wrapped: nil).order(:epoch)
        .map { |e| { epoch: e.epoch, previous_key_wrapped: b64.call(e.previous_key_wrapped) } }
    end

    # Everyone a rotate must cover: active role holders, with their role and
    # whether they hold the current epoch's key.
    attribute :holders do |root|
      current = Disk::KeyGrant.where(scope_node_id: root.id, epoch: root.scope_epoch).pluck(:membership_id).to_set
      roles = if root.share_id
        Disk::ShareMembership.where(share_id: root.share_id).pluck(:membership_id, :role).to_h
      else
        Disk::Grant.where(node_id: root.id).pluck(:membership_id, :role).to_h.merge(root.custodian_membership_id => Disk::ROLE_MANAGE)
      end
      Membership.where(id: Disk::Sealing.holder_ids(root)).includes(:user, :agents).order(:id).map do |m|
        Disk::MemberRefSerializer.new(m).to_h.merge(role: roles[m.id], has_key: current.include?(m.id))
      end
    end

    # The removal dialog lists these with Revoke (6.9); managers only.
    attribute :links do |root|
      next [] unless params[:manager]

      Disk::Link.active.where(node_id: Disk::Node.where(seal_scope_node_id: root.id).select(:id)).includes(:node)
        .order(:created_at).map { |l| { id: l.key, node_id: l.node.key, expires_at: l.expires_at, created_at: l.created_at } }
    end
  end
end
