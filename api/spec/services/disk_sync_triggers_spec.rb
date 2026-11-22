require "rails_helper"

# docs/Disk-Sync.md — Disk change tracking lives in Postgres triggers that
# schema.rb cannot express. If "is installed" fails, the schema-load hook
# (config/initializers/sync_triggers.rb) stopped installing them.
RSpec.describe Disk::SyncTriggers do
  include_context "disk org"

  let(:share) { make_share("Marketing") }

  def seq(node) = Disk::Node.where(id: node.id).pick(:change_seq)
  def events(kind) = Disk::SyncEvent.where(kind: kind)

  it "is installed in this database" do
    names = ActiveRecord::Base.connection.select_values(
      "SELECT tgname FROM pg_trigger WHERE tgname LIKE 'disk_sync_%' AND NOT tgisinternal"
    )
    expect(names).to match_array(described_class.names)
  end

  it "stamps inserts and update_all writes" do
    node = make_folder(share.root_node, "A")
    before = seq(node)
    expect(before).to be_present
    Disk::Node.where(id: node.id).update_all(name: "B")
    expect(seq(node)).to be > before
  end

  it "re-stamps a moved folder's contents" do
    a = make_folder(share.root_node, "A")
    b = make_folder(share.root_node, "B")
    child = make_folder(a, "Child")
    grandchild = make_folder(child, "Grandchild")
    before = [seq(child), seq(grandchild)]
    a.update!(parent: b)
    expect([seq(child), seq(grandchild)].zip(before)).to all(satisfy { |now, was| now > was })
  end

  it "leaves a deleted event for a purged node and for one that moved to another org" do
    node = make_folder(share.root_node, "A")
    Disk::Node.where(id: node.id).delete_all
    expect(events("deleted").where(organization_id: org.id, node_key: node.key)).to exist

    moved = make_folder(share.root_node, "B")
    personal = member_user.personal_organization
    Disk::Node.where(id: moved.id).update_all(organization_id: personal.id)
    expect(events("deleted").where(organization_id: org.id, node_key: moved.key)).to exist
  end

  it "leaves one acl event per org for access changes, the grantee's org included" do
    share
    expect { Disk::ShareMembership.create!(organization: org, share: share, membership: member, role: "view") }
      .to change { events("acl").where(organization_id: org.id).count }.by(1)

    theirs = make_folder(c_root(other), "For Mo")
    their_org = theirs.organization_id
    grant = nil
    # The node's org (their personal workspace) and the grantee's (this team).
    expect { grant = Disk::Grant.create!(organization_id: their_org, node: theirs, membership: member, role: "view") }
      .to change { events("acl").where(organization_id: their_org).count }.by(1)
      .and change { events("acl").where(organization_id: org.id).count }.by(1)
    expect { grant.destroy! }.to change { events("acl").where(organization_id: org.id).count }.by(1)

    expect { share.update!(archived_at: Time.current) }.to change { seq(share.root_node) }
  end

  it "keeps each org's newest expired event as its prune watermark" do
    old = 2.times.map { |i| Disk::SyncEvent.create!(organization_id: org.id, kind: "acl", change_seq: i + 1, change_xid: i + 1, created_at: 40.days.ago) }
    fresh = Disk::SyncEvent.create!(organization_id: org.id, kind: "acl", change_seq: 9, change_xid: 9, created_at: 1.day.ago)
    Disk::SyncEvent.where(organization_id: org.id).where.not(id: old.map(&:id) + [fresh.id]).delete_all
    Disk::SyncEvent.prune!
    expect(Disk::SyncEvent.where(organization_id: org.id).pluck(:id)).to contain_exactly(old.last.id, fresh.id)
    expect(Disk::SyncEvent.watermark_xid([org.id])).to eq(2)
  end
end
