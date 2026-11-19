require "rails_helper"

RSpec.describe Disk::Access do
  include_context "disk org"

  let(:admin) { create(:membership, organization: org, role: "admin") }
  let(:share) { make_share("Marketing") }
  let(:folder) { make_folder(share.root_node, "Launch") }
  let(:deep) { make_folder(folder, "Assets") }
  let(:my_c) { make_folder(c_root(member), "Private") }

  # Table over the role sources (docs/plans/disk-build.md section 5).
  # Each row: who, how the node is reached, expected role on `deep`.
  [
    ["custodian on their own C:\\", ->(t) { [t.member, t.make_folder(t.my_c, "x")] }, "manage"],
    ["owner on someone else's C:\\", ->(t) { [t.owner, t.make_folder(t.my_c, "x")] }, nil],
    ["admin on someone else's C:\\", ->(t) { [t.admin, t.make_folder(t.my_c, "x")] }, nil],
    ["owner on a share", ->(t) { [t.owner, t.deep] }, "manage"],
    ["admin on a share", ->(t) { [t.admin, t.deep] }, "manage"],
    ["member of an assigned share with view", lambda { |t|
      Disk::ShareMembership.create!(organization: t.org, share: t.share, membership: t.member, role: "view")
      [t.member, t.deep]
    }, "view"],
    ["member outside an assigned share", ->(t) { [t.member, t.deep] }, nil],
    ["anyone on an org-open share", lambda { |t|
      t.share.update!(openness: "org", org_role: "edit")
      [t.member, t.deep]
    }, "edit"],
    ["grant on an ancestor reaches down", lambda { |t|
      Disk::Grant.create!(organization: t.org, node: t.folder, membership: t.member, role: "edit")
      [t.member, t.deep]
    }, "edit"],
    ["grant on a child does not reach up", lambda { |t|
      Disk::Grant.create!(organization: t.org, node: t.deep, membership: t.member, role: "edit")
      [t.member, t.folder]
    }, nil],
    ["grants only widen: share view + grant edit", lambda { |t|
      Disk::ShareMembership.create!(organization: t.org, share: t.share, membership: t.member, role: "view")
      Disk::Grant.create!(organization: t.org, node: t.folder, membership: t.member, role: "edit")
      [t.member, t.deep]
    }, "edit"],
    ["grant on a colleague's C:\\ folder", lambda { |t|
      Disk::Grant.create!(organization: t.org, node: t.my_c, membership: t.other, role: "view")
      [t.other, t.make_folder(t.my_c, "x")]
    }, "view"],
    ["archived share caps members at view", lambda { |t|
      Disk::ShareMembership.create!(organization: t.org, share: t.share, membership: t.member, role: "manage")
      t.share.update!(archived_at: Time.current)
      [t.member, t.deep]
    }, "view"],
    ["trashed share hides from its members", lambda { |t|
      Disk::ShareMembership.create!(organization: t.org, share: t.share, membership: t.member, role: "manage")
      t.share.update!(trashed_at: Time.current)
      [t.member, t.deep]
    }, nil],
    ["trashed share hides grants inside it", lambda { |t|
      Disk::Grant.create!(organization: t.org, node: t.folder, membership: t.member, role: "edit")
      t.share.update!(trashed_at: Time.current)
      [t.member, t.deep]
    }, nil],
    ["trashed share stays open to admins", lambda { |t|
      t.share.update!(trashed_at: Time.current)
      [t.admin, t.deep]
    }, "manage"]
  ].each do |label, setup, expected|
    it "#{label} -> #{expected || 'none'}, and scope_for agrees" do
      who, node = setup.call(self)
      expect(described_class.role(who, node)).to eq(expected)
      expect(described_class.scope_for(who).exists?(node.id)).to eq(!expected.nil?)
    end
  end

  it "scope_for never reaches another org" do
    foreign_node
    expect(described_class.scope_for(owner).where(organization_id: outsider_org.id)).to be_empty
  end

  it "sources name where access comes from" do
    Disk::ShareMembership.create!(organization: org, share: share, membership: member, role: "view")
    Disk::Grant.create!(organization: org, node: folder, membership: member, role: "edit")
    sources = described_class.sources(member, deep)
    expect(sources.map { |s| [s.kind, s.role] }).to contain_exactly(%i[share_member view].then { |k, r| [k, r.to_s] },
                                                                    [:grant, "edit"])
    expect(sources.find { |s| s.kind == :grant }.node).to eq(folder)
  end
end
