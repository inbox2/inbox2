require "rails_helper"

# Package 9, sealing step one (build guide 6.2, 6.5, 6.7; spec F7, F7b): scopes,
# key holders, rotation, the leaver freeze and offboarding with real scopes.
RSpec.describe "Disk sealed scopes", type: :request do
  include_context "disk org"

  let(:owner_h) { auth_headers(owner_user) }
  let(:member_h) { auth_headers(member_user) }
  let(:other_h) { auth_headers(other_user) }

  before { give_identity(owner, member, other) }

  def json = response.parsed_body
  def err = json["errors"]&.first&.dig("message")

  describe "creating scopes" do
    it "creates a sealed share: assigned, the creator its manager holding the epoch 1 key" do
      key = sealed_key
      post disk_path("/shares"), params: { name: "Board", sealed: true, sealed_key: b64(key) }, headers: owner_h, as: :json
      expect(response).to have_http_status(:created)
      expect(json["share"]["sealed"]).to be(true)
      share = Disk::Share.find_by!(key: json["share"]["id"])
      root = share.root_node
      expect(share.openness).to eq("assigned")
      expect(root).to have_attributes(sealed: true, seal_scope_node_id: root.id, scope_epoch: 1, rotation_due: false)
      expect(share.share_memberships.sole).to have_attributes(membership_id: owner.id, role: "manage")
      expect(Disk::KeyGrant.sole).to have_attributes(scope_node_id: root.id, membership_id: owner.id, epoch: 1, sealed_key: key)
      expect(Disk::ScopeEpoch.sole).to have_attributes(epoch: 1, previous_key_wrapped: nil)
    end

    it "refuses an org-open sealed share, a missing key, no identity key, a plain member and a plan without E2EE" do
      post disk_path("/shares"), params: { name: "B", sealed: true, sealed_key: b64(sealed_key), openness: "org" }, headers: owner_h, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      post disk_path("/shares"), params: { name: "B", sealed: true }, headers: owner_h, as: :json
      expect(response).to have_http_status(:bad_request).or have_http_status(:unprocessable_content)
      post disk_path("/shares"), params: { name: "B", sealed: true, sealed_key: b64("short") }, headers: owner_h, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      post disk_path("/shares"), params: { name: "B", sealed: true, sealed_key: b64(sealed_key) }, headers: member_h, as: :json
      expect(response).to have_http_status(:forbidden)
      UserKey.where(user: owner_user).delete_all
      post disk_path("/shares"), params: { name: "B", sealed: true, sealed_key: b64(sealed_key) }, headers: owner_h, as: :json
      expect(json["code"]).to eq("disk_no_identity_key")
      give_identity(owner)
      allow_any_instance_of(Organization).to receive(:e2ee_entitled?).and_return(false)
      post disk_path("/shares"), params: { name: "B", sealed: true, sealed_key: b64(sealed_key) }, headers: owner_h, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(Disk::Share.count).to eq(0)
    end

    it "never opens a sealed share to the org" do
      share = make_sealed_share
      patch disk_path("/shares/#{share.key}"), params: { openness: "org" }, headers: owner_h, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(share.reload.openness).to eq("assigned")
    end

    it "creates a sealed folder on the creator's C:\\ with a client-proposed id" do
      id = new_id("dnd")
      post disk_path("/nodes"), params: { parent_id: c_root(member).key, kind: "folder", sealed: true, id: id,
                                          metadata_ciphertext: b64(envelope), key_epoch: 1, sealed_key: b64(sealed_key) },
                                headers: member_h, as: :json
      expect(response).to have_http_status(:created)
      expect(json["node"]).to include("id" => id, "name" => nil, "sealed" => true, "key_epoch" => 1)
      node = Disk::Node.find_by!(key: id)
      expect(node).to have_attributes(seal_scope_node_id: node.id, scope_epoch: 1)
      expect(Disk::KeyGrant.where(scope_node_id: node.id, membership_id: member.personal_membership_id, epoch: 1)).to exist
    end

    it "refuses sealed folders in a share, on someone else's C:\\, inside a scope as a new scope, and bad ids" do
      body = { kind: "folder", sealed: true, metadata_ciphertext: b64(envelope), key_epoch: 1, sealed_key: b64(sealed_key) }
      share = make_share("Open")
      post disk_path("/nodes"), params: body.merge(parent_id: share.root_node.key, id: new_id("dnd")), headers: owner_h, as: :json
      expect(err).to match(/sealed share/)
      Disk::Grant.create!(organization: org, node: c_root(member), membership: other, role: "edit")
      post disk_path("/nodes"), params: body.merge(parent_id: c_root(member).key, id: new_id("dnd")), headers: other_h, as: :json
      expect(response).to have_http_status(:forbidden)
      post disk_path("/nodes"), params: body.merge(parent_id: c_root(member).key, id: "dnd_short"), headers: member_h, as: :json
      expect(err).to match(/21 characters/)
      taken = make_folder(c_root(member), "Taken")
      post disk_path("/nodes"), params: body.merge(parent_id: c_root(member).key, id: taken.key), headers: member_h, as: :json
      expect(response).to have_http_status(:conflict)
      expect(json["code"]).to eq("disk_id_taken")
      post disk_path("/nodes"), params: body.merge(parent_id: c_root(member).key, id: new_id("dnd"), key_epoch: 2), headers: member_h, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      post disk_path("/nodes"), params: body.merge(parent_id: foreign_node.key, id: new_id("dnd")), headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "makes sealed children only with sealed fields under the current epoch" do
      vault = make_sealed_folder(member)
      post disk_path("/nodes"), params: { parent_id: vault.key, name: "Plain" }, headers: member_h, as: :json
      expect(err).to match(/sealing client/)
      id = new_id("dnd")
      post disk_path("/nodes"), params: { parent_id: vault.key, kind: "page", id: id, metadata_ciphertext: b64(envelope), key_epoch: 1 },
                                headers: member_h, as: :json
      expect(response).to have_http_status(:created)
      expect(Disk::Node.find_by!(key: id)).to have_attributes(sealed: true, seal_scope_node_id: vault.id, kind: "page")
      post disk_path("/nodes"), params: { parent_id: vault.key, kind: "folder", id: new_id("dnd"), metadata_ciphertext: "bm90IGFuIGVudmVsb3Bl", key_epoch: 1 },
                                headers: member_h, as: :json
      expect(err).to match(/sealed envelope/)
    end

    it "shows owners and admins a sealed share's top folder but nothing inside it" do
      share = make_sealed_share(holders: { member => "manage" })
      inner = make_sealed_node(share.root_node)
      get disk_path("/nodes/#{share.root_node.key}/children"), headers: owner_h
      expect(json["nodes"]).to eq([])
      get disk_path("/nodes/#{inner.key}"), headers: owner_h
      expect(response).to have_http_status(:not_found)
      get disk_path("/nodes/#{share.root_node.key}"), headers: owner_h
      expect(response).to have_http_status(:ok)
      patch disk_path("/shares/#{share.key}"), params: { name: "Renamed" }, headers: owner_h, as: :json
      expect(response).to have_http_status(:ok)
      get disk_path("/shares/#{share.key}/members"), headers: owner_h
      expect(json["members"].pluck("membership_id")).to eq([member.key])
      post disk_path("/nodes"), params: { parent_id: share.root_node.key, kind: "folder", id: new_id("dnd"),
                                          metadata_ciphertext: b64(envelope), key_epoch: 1 }, headers: owner_h, as: :json
      expect(response).to have_http_status(:forbidden)
      get disk_path("/nodes/#{inner.key}"), headers: member_h
      expect(response).to have_http_status(:ok)
    end

    it "does not let a grant above a sealed C:\\ folder reach into it" do
      parent = make_folder(c_root(member), "Projects")
      vault = make_sealed_folder(member, parent: parent)
      Disk::Grant.create!(organization: org, node: parent, membership: other, role: "edit")
      get disk_path("/nodes/#{parent.key}/children"), headers: other_h
      expect(json["nodes"]).to eq([])
      get disk_path("/nodes/#{vault.key}"), headers: other_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "key holders" do
    let(:share) { make_sealed_share }
    let(:root) { share.root_node }

    def add(who, **body) = put(disk_path("/shares/#{share.key}/members/#{who.key}"), params: { role: "edit", **body }, headers: owner_h, as: :json)

    it "adds a member only with their key for the current epoch" do
      add(member)
      expect(err).to match(/needs its key/)
      add(member, sealed_key: b64(sealed_key), epoch: 2)
      expect(response).to have_http_status(:conflict)
      expect(json).to include("code" => "epoch_changed", "current_epoch" => 1)
      UserKey.where(user: member_user).delete_all
      add(member, sealed_key: b64(sealed_key), epoch: 1)
      expect(json["code"]).to eq("disk_no_identity_key")
      give_identity(member)
      add(member, sealed_key: b64(sealed_key), epoch: 1)
      expect(response).to have_http_status(:ok)
      expect(Disk::KeyGrant.where(scope_node_id: root.id, membership_id: member.id, epoch: 1)).to exist
      add(member, role: "view") # a role change keeps the key already held
      expect(response).to have_http_status(:ok)
      expect(share.share_memberships.find_by!(membership: member).role).to eq("view")
      expect(share.share_memberships.count).to eq(2)
    end

    it "refuses ordinary removal on a sealed share and a sealed folder" do
      key_grant!(root, member)
      share.share_memberships.create!(organization: org, membership: member, role: "view")
      delete disk_path("/shares/#{share.key}/members/#{member.key}"), headers: owner_h
      expect(json["code"]).to eq("disk_use_rotate")
      vault = make_sealed_folder(member)
      delete disk_path("/nodes/#{vault.key}/grants/#{other.key}"), headers: member_h
      expect(json["code"]).to eq("disk_use_rotate")
    end

    it "grants on a sealed C:\\ folder's root with the key, and refuses grants anywhere else in a scope" do
      vault = make_sealed_folder(member)
      inner = make_sealed_node(vault)
      put disk_path("/nodes/#{vault.key}/grants/#{other.key}"), params: { role: "view" }, headers: member_h, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      put disk_path("/nodes/#{vault.key}/grants/#{other.key}"), params: { role: "view", sealed_key: b64(sealed_key), epoch: 1 },
                                                                headers: member_h, as: :json
      expect(response).to have_http_status(:ok)
      get disk_path("/nodes/#{inner.key}"), headers: other_h
      expect(response).to have_http_status(:ok)
      put disk_path("/nodes/#{inner.key}/grants/#{owner.key}"), params: { role: "view", sealed_key: b64(sealed_key), epoch: 1 },
                                                                headers: member_h, as: :json
      expect(json["code"]).to eq("disk_sealed_whole")
      expect(Disk::Grant.where(node: inner)).not_to exist
      put disk_path("/nodes/#{root.key}/grants/#{member.key}"), params: { role: "view", sealed_key: b64(sealed_key), epoch: 1 },
                                                               headers: owner_h, as: :json
      expect(err).to match(/as its members/)
    end

    it "lists members' identity keys, null without one, nothing from other orgs" do
      UserKey.where(user: other_user).delete_all
      stranger = create(:membership, organization: outsider_org)
      get disk_path("/keys/members"), params: { ids: [member.key, other.key, stranger.key].join(",") }, headers: owner_h
      expect(response).to have_http_status(:ok)
      keys = json["members"].to_h { |m| [m["membership_id"], m["public_key"]] }
      expect(keys.keys).to contain_exactly(member.key, other.key)
      expect(keys[member.key]).to eq(UserKey.find_by!(user: member_user).public_key)
      expect(keys[other.key]).to be_nil
      get disk_path("/keys/members"), params: { ids: "" }, headers: owner_h
      expect(response).to have_http_status(:bad_request).or have_http_status(:unprocessable_content)
      get "/api/v1/orgs/#{outsider_org.key}/disk/keys/members", params: { ids: member.key }, headers: owner_h
      expect(response).to have_http_status(:not_found)
    end

    it "gives a holder the scope: epoch, their grants, the chain and the holders" do
      key_grant!(root, member)
      share.share_memberships.create!(organization: org, membership: member, role: "view")
      Disk::ScopeEpoch.create!(organization: org, scope_node: root, epoch: 2, previous_key_wrapped: prev = envelope)
      key_grant!(root, owner, epoch: 2)
      root.update!(scope_epoch: 2)
      get disk_path("/scopes/#{root.key}"), headers: owner_h
      scope = json["scope"]
      expect(scope).to include("id" => root.key, "epoch" => 2, "rotation_due" => false)
      expect(scope["grant"]["epoch"]).to eq(2)
      expect(scope["grants"].pluck("epoch")).to eq([2, 1])
      expect(scope["epochs"]).to eq([{ "epoch" => 2, "previous_key_wrapped" => b64(prev) }])
      expect(scope["holders"].to_h { |h| [h["id"], h["has_key"]] }).to eq(owner.key => true, member.key => false)

      get disk_path("/scopes/#{make_folder(c_root(member), 'Plain').key}"), headers: member_h
      expect(response).to have_http_status(:unprocessable_content)
      get disk_path("/scopes/#{foreign_node.key}"), headers: owner_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "rotation" do
    let(:share) { make_sealed_share(holders: { owner => "manage", member => "edit", other => "view" }) }
    let(:root) { share.root_node }

    def rotate(remove:, grants:, epoch: 2, headers: owner_h)
      post disk_path("/scopes/#{root.key}/rotate"),
           params: { remove: remove.map(&:key), epoch: epoch, previous_key_wrapped: b64(envelope),
                     grants: grants.map { |m| { membership_id: m.key, sealed_key: b64(sealed_key) } } },
           headers: headers, as: :json
    end

    it "removes a holder, moves to the next epoch and grants exactly the rest" do
      rotate(remove: [other], grants: [owner, member])
      expect(response).to have_http_status(:ok)
      expect(json["scope"]).to include("epoch" => 2, "rotation_due" => false)
      expect(root.reload.scope_epoch).to eq(2)
      expect(share.share_memberships.pluck(:membership_id)).to contain_exactly(owner.id, member.id)
      expect(Disk::KeyGrant.where(membership: other)).not_to exist
      expect(Disk::KeyGrant.where(scope_node: root, epoch: 2).pluck(:membership_id)).to contain_exactly(owner.id, member.id)
      expect(Disk::ScopeEpoch.find_by!(scope_node: root, epoch: 2).previous_key_wrapped).to be_present
      expect(Disk::Event.find_by!(action: "key_rotated").detail).to eq("epoch" => 2, "removed" => [other.key])
      get disk_path("/nodes/#{root.key}"), headers: other_h
      expect(response).to have_http_status(:not_found)
    end

    it "names who is missing or extra, and refuses any epoch but current plus one" do
      rotate(remove: [other], grants: [owner])
      expect(response).to have_http_status(:unprocessable_content)
      expect(json).to include("missing" => [member.key], "extra" => [])
      rotate(remove: [other], grants: [owner, member, other])
      expect(json).to include("missing" => [], "extra" => [other.key])
      rotate(remove: [other], grants: [owner, member], epoch: 3)
      expect(response).to have_http_status(:conflict)
      expect(json["current_epoch"]).to eq(1)
      rotate(remove: [create(:membership, organization: org)], grants: [owner, member, other])
      expect(json).to have_key("not_holders")
      expect(root.reload.scope_epoch).to eq(1)
      expect(share.share_memberships.count).to eq(3)
    end

    it "is for managers holding the key, in their own org" do
      rotate(remove: [other], grants: [owner, member], headers: member_h)
      expect(response).to have_http_status(:forbidden)
      post "/api/v1/orgs/#{outsider_org.key}/disk/scopes/#{root.key}/rotate", params: { epoch: 2 }, headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)
      post disk_path("/scopes/#{foreign_node.key}/rotate"), params: { epoch: 2 }, headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "removes a team member from a sealed C:\\ folder (its root lives in the personal org)" do
      vault = make_sealed_folder(member)
      put disk_path("/nodes/#{vault.key}/grants/#{other.key}"), params: { role: "view", sealed_key: b64(sealed_key), epoch: 1 },
                                                                headers: member_h, as: :json
      expect(response).to have_http_status(:ok)
      custodian = Membership.find(vault.custodian_membership_id)

      post disk_path("/scopes/#{vault.key}/rotate"),
           params: { remove: [other.key], epoch: 2, previous_key_wrapped: b64(envelope),
                     grants: [{ membership_id: custodian.key, sealed_key: b64(sealed_key) }] },
           headers: member_h, as: :json

      expect(response).to have_http_status(:ok)
      expect(Disk::Grant.where(node: vault, membership: other)).not_to exist
    end

    it "clears rotation_due with remove: [] once every remaining holder has the new key" do
      root.update!(rotation_due: true)
      rotate(remove: [], grants: [owner, member, other])
      expect(response).to have_http_status(:ok)
      expect(root.reload).to have_attributes(rotation_due: false, scope_epoch: 2)
    end

    it "transfers the key to another member with manage" do
      outsider = create(:membership, organization: org, user: create(:user))
      give_identity(outsider)
      post disk_path("/scopes/#{root.key}/transfer"), params: { membership_id: outsider.key, sealed_key: b64(sealed_key), epoch: 1 },
                                                      headers: owner_h, as: :json
      expect(response).to have_http_status(:ok)
      expect(share.share_memberships.find_by!(membership: outsider).role).to eq("manage")
      expect(Disk::KeyGrant.where(scope_node: root, membership: outsider, epoch: 1)).to exist
      post disk_path("/scopes/#{root.key}/transfer"), params: { membership_id: outsider.key, sealed_key: b64(sealed_key), epoch: 1 },
                                                      headers: other_h, as: :json
      expect(response).to have_http_status(:forbidden)
      post disk_path("/scopes/#{foreign_node.key}/transfer"), params: { membership_id: outsider.key, sealed_key: b64(sealed_key), epoch: 1 },
                                                              headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "a key holder leaving freezes the scope" do
    let!(:share) { make_sealed_share(holders: { owner => "manage", member => "edit" }) }
    let(:root) { share.root_node }

    def frozen? = root.reload.rotation_due && !Disk::KeyGrant.exists?(membership_id: member.id)

    it "on removal from the org" do
      delete "/api/v1/orgs/#{org.key}/members/#{member.key}", headers: owner_h
      expect(response).to have_http_status(:no_content)
      expect(root.reload.rotation_due).to be(true)
      expect(Disk::KeyGrant.where(scope_node: root).pluck(:membership_id)).to eq([owner.id])
    end

    it "on being disabled by an admin" do
      patch "/api/v1/admin/users/#{member_user.key}/status", params: { status: "disabled", scope: "membership", org_id: org.key },
                                                            headers: owner_h, as: :json
      expect(response).to have_http_status(:ok)
      expect(frozen?).to be(true)
    end

    it "on a status saved through the model" do
      member.update!(status: Membership::STATUS_DISABLED)
      expect(frozen?).to be(true)
    end

    it "on a deleted account" do
      member_user.destroy!
      expect(root.reload.rotation_due).to be(true)
      expect(Disk::KeyGrant.where(membership_id: member.id)).not_to exist
    end

    it "on a seat limit after a downgrade" do
      org.apply_plan_limits!(Plan.free)
      expect(frozen?).to be(true)
    end

    it "on SaaS ops disabling the user", :saas do
      post "/api/v1/saas/users/#{member_user.key}/disable", headers: saas_headers(create(:admin_credential))
      expect(response).to have_http_status(:ok)
      expect(frozen?).to be(true)
    end

    it "then refuses writes with rotation_required, keeps reads, trash and deletes, until a rotate" do
      file = make_sealed_file(root)
      folder = make_sealed_node(root)
      root.update!(rotation_due: true)
      post disk_path("/nodes"), params: { parent_id: root.key, kind: "folder", id: new_id("dnd"), metadata_ciphertext: b64(envelope), key_epoch: 1 },
                                headers: owner_h, as: :json
      expect(json).to include("code" => "rotation_required", "current_epoch" => 1)
      expect(response).to have_http_status(:conflict)
      post disk_path("/uploads"), params: { parent_id: root.key, size_bytes: 32, sealed: true, chunk_bytes: 1.megabyte, key_epoch: 1,
                                            id: new_id("dnd"), metadata_ciphertext: b64(envelope) }, headers: owner_h, as: :json
      expect(json["code"]).to eq("rotation_required")
      patch disk_path("/nodes/#{file.key}"), params: { metadata_ciphertext: b64(envelope), key_epoch: 1 }, headers: owner_h, as: :json
      expect(json["code"]).to eq("rotation_required")
      post disk_path("/nodes/#{file.key}/copy"), params: { target_id: folder.key }, headers: owner_h, as: :json
      expect(json["code"]).to eq("rotation_required")
      post disk_path("/nodes/#{file.key}/move"), params: { target_id: folder.key }, headers: owner_h, as: :json
      expect(json["code"]).to eq("rotation_required")
      get disk_path("/nodes/#{file.key}/download"), headers: owner_h
      expect(response).to have_http_status(:ok)
      delete disk_path("/nodes/#{file.key}"), headers: owner_h
      expect(response).to have_http_status(:ok)
      post disk_path("/nodes/#{file.key}/restore"), headers: owner_h
      expect(json["code"]).to eq("rotation_required")
      delete disk_path("/nodes/#{file.key}/purge"), headers: owner_h
      expect(response).to have_http_status(:no_content)
    end
  end
end
