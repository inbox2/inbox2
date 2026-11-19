# Live editing of an unsealed Disk page (spec F6), the DraftChannel Yjs relay
# pattern with Disk access on top. The server relays Yjs updates and awareness
# without storing them; clients save snapshots through PUT /pages/:node_id.
#
# Subscribe with { channel: "DiskPageChannel", org_id, node_id }. View role may
# read and send awareness (cursors); edit role may send updates. Access is
# re-read on every update and every RECHECK, so a member who loses access is
# cut off with "access_revoked" and a role change arrives as "role_changed".
# A message is never echoed to the subscription that sent it.
#
# Sealed pages (docs/plans/disk-build.md 6.10) relay only ciphertext. Updates
# are written through POST /pages/:node_id/updates and broadcast here as
# "sealed_update" { seq, epoch, update, membership_id } once their row has
# committed; a snapshot saved through PUT /pages/:node_id arrives as
# "sealed_snapshot" { seq, epoch, revision, membership_id }. Plain sync_update
# is ignored on a sealed page. sync_awareness { update, epoch } is relayed as
# "yjs_awareness" with its epoch while that is the scope's current epoch, and
# never stored.
class DiskPageChannel < ApplicationCable::Channel
  RECHECK = 15.seconds

  periodically :recheck_access, every: RECHECK

  # Tells everyone on the page that a snapshot was saved (Disk::NodeOps#save_page).
  # A save with no ydoc (an agent writing markdown over MCP) is "page_replaced":
  # editors drop their Yjs state and rebuild from the markdown in GET /pages.
  def self.saved(node, page, membership)
    broadcast_to(node, { type: page.ydoc.nil? ? "page_replaced" : "page_saved", revision: page.revision,
                         membership_id: membership.key, name: Disk.display_name(membership),
                         agent: membership.agent?, timestamp: Time.current.iso8601 })
  end

  # A sealed update, after its row committed (Disk::NodeOps#append_page_update).
  def self.sealed_update(node, row, membership)
    broadcast_to(node, { type: "sealed_update", seq: row.seq, epoch: row.epoch,
                         update: Base64.strict_encode64(row.ciphertext), membership_id: membership.key,
                         timestamp: Time.current.iso8601 })
  end

  def self.sealed_snapshot(node, page, membership)
    broadcast_to(node, { type: "sealed_snapshot", seq: page.snapshot_seq, epoch: page.snapshot_epoch,
                         revision: page.revision, membership_id: membership.key, timestamp: Time.current.iso8601 })
  end

  def subscribed
    @sid = SecureRandom.hex(8)
    @membership = find_membership
    @node = @membership && visible_page
    @role = @node && Disk::Access.role(@membership, @node)
    return reject if @role.nil?

    stream_for @node, coder: ActiveSupport::JSON do |message|
      transmit(message) unless message["sid"] == @sid
    end
    relay("editor_joined")
  end

  # A Yjs document update (base64). Needs edit.
  def sync_update(data)
    return if @node.sealed? # sealed updates are stored first, through the API
    return unless recheck_access && Disk.role_rank(@role) >= Disk.role_rank(Disk::ROLE_EDIT)
    return unless @membership.organization.disk_writable? # read-only after a downgrade

    relay("yjs_update", update: data["update"])
  end

  # A Yjs awareness update (base64): cursors and presence. Viewers may send it.
  def sync_awareness(data)
    return if @revoked
    return relay("yjs_awareness", update: data["update"]) unless @node.sealed?

    epoch = Disk::Node.where(id: @node.seal_scope_node_id).pick(:scope_epoch)
    relay("yjs_awareness", update: data["update"], epoch: epoch) if data["epoch"].to_i == epoch
  end

  def unsubscribed
    relay("editor_left") if @role && !@revoked
  end

  private

  # Truthy while the member still reaches the page.
  def recheck_access
    return false if @revoked

    membership = Membership.find_by(id: @membership.id, status: Membership::STATUS_ACTIVE)
    node = membership&.organization&.disk_readable? &&
           Disk::Access.scope_for(membership).live.find_by(id: @node.id)
    role = node && Disk::Access.role(membership, node)
    if role.nil?
      @revoked = true
      transmit({ type: "access_revoked" })
      stop_all_streams
    elsif role != @role
      @role = role
      transmit({ type: "role_changed", role: role })
    end
    !@revoked
  end

  def find_membership
    org = Organization.find_by(key: params[:org_id].to_s) || Organization.find_by(slug: params[:org_id].to_s)
    return unless org&.disk_readable?

    org.memberships.find_by(user: current_user, status: Membership::STATUS_ACTIVE)
  end

  def visible_page
    Disk::Access.scope_for(@membership).live.find_by(key: Disk::Node.key_for(params[:node_id]), kind: Disk::Node::KIND_PAGE)
  end

  def relay(type, **payload)
    self.class.broadcast_to(@node, { type: type, sid: @sid, user_id: current_user.key,
                                     membership_id: @membership.key, name: display_name,
                                     timestamp: Time.current.iso8601, **payload })
  end

  def display_name = current_user.display_name.presence || current_user.username
end
