require "rails_helper"

# Spec F6 live collaboration on unsealed pages, authorised through Disk::Access.
RSpec.describe DiskPageChannel, type: :channel do
  include_context "disk org"

  let(:share) { make_share("Marketing") }
  let(:page) { make_folder(share.root_node, "Plan").tap { |n| n.update!(kind: Disk::Node::KIND_PAGE) } }
  let(:update) { Base64.strict_encode64("yjs-update") }

  def join(user, node = page, org_id: org.key)
    stub_connection current_user: user
    subscribe(org_id: org_id, node_id: node.key)
  end

  def grant(membership, role) = share.share_memberships.create!(organization: org, membership: membership, role: role)

  it "lets an editor relay updates and awareness, tagged with who sent them" do
    grant(member, "edit")
    join(member_user, org_id: org.slug)
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_for(page)
    expect { perform :sync_update, update: update }.to have_broadcasted_to(page)
      .with(hash_including("type" => "yjs_update", "update" => update, "membership_id" => member.key,
                           "user_id" => member_user.key))
    expect { perform :sync_awareness, update: update }.to have_broadcasted_to(page)
      .with(hash_including("type" => "yjs_awareness"))
  end

  it "lets a viewer follow and send awareness, but not edit" do
    grant(member, "view")
    join(member_user)
    expect(subscription).to be_confirmed
    expect { perform :sync_update, update: update }.not_to have_broadcasted_to(page)
    expect { perform :sync_awareness, update: update }.to have_broadcasted_to(page)
  end

  it "rejects people without access, other orgs, non-pages and trashed pages" do
    join(member_user)
    expect(subscription).to be_rejected
    join(owner_user, page, org_id: outsider_org.key)
    expect(subscription).to be_rejected
    join(owner_user, share.root_node)
    expect(subscription).to be_rejected
    theirs = make_folder(foreign_share.root_node, "Theirs").tap { |n| n.update!(kind: Disk::Node::KIND_PAGE) }
    join(owner_user, theirs, org_id: outsider_org.key)
    expect(subscription).to be_rejected

    Disk::NodeOps.new(owner).trash(page)
    join(owner_user)
    expect(subscription).to be_rejected
  end

  it "cuts off a member whose access is removed mid-session, and reports a role change" do
    row = grant(member, "edit")
    join(member_user)
    row.update!(role: "view")
    subscription.send(:recheck_access)
    expect(transmissions.last).to eq("type" => "role_changed", "role" => "view")

    row.destroy!
    expect { perform :sync_update, update: update }.not_to have_broadcasted_to(page)
    expect(transmissions.last).to eq("type" => "access_revoked")
    expect(subscription.streams).to be_empty
    expect { perform :sync_awareness, update: update }.not_to have_broadcasted_to(page)
  end

  it "on a sealed page relays only current-epoch awareness and never a plain update (build guide 6.10)" do
    sealed = make_sealed_node(make_sealed_share(holders: { member => "edit" }).root_node, kind: Disk::Node::KIND_PAGE)
    join(member_user, sealed)
    expect(subscription).to be_confirmed
    expect { perform :sync_update, update: update }.not_to have_broadcasted_to(sealed)
    expect { perform :sync_awareness, update: update, epoch: 2 }.not_to have_broadcasted_to(sealed)
    expect { perform :sync_awareness, update: update, epoch: 1 }.to have_broadcasted_to(sealed)
      .with(hash_including("type" => "yjs_awareness", "update" => update, "epoch" => 1))
  end

  it "tells the page's editors when a snapshot is saved" do
    expect { described_class.saved(page, Disk::Page.for(page).tap { |p| p.assign_attributes(revision: 4, ydoc: "y") }, owner) }
      .to have_broadcasted_to(page).with(hash_including("type" => "page_saved", "revision" => 4,
                                                        "membership_id" => owner.key))
  end
end
