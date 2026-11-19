require "rails_helper"

# Package 9, sealing step one (build guide 6.6 to 6.10; spec F7, F7b): the epoch
# rule at every commit point, sealed uploads, copies, restores, moves across
# scopes, the staged switch, sealed file links and sealed pages.
RSpec.describe "Disk sealed content", type: :request do
  include_context "disk org"

  let(:owner_h) { auth_headers(owner_user) }
  let(:member_h) { auth_headers(member_user) }
  let!(:share) { make_sealed_share(holders: { owner => "manage", member => "edit" }) }
  let(:root) { share.root_node }

  def json = response.parsed_body
  def err = json["errors"]&.first&.dig("message")

  # Moves the scope to epoch 2 as a rotate would, owner and member keeping the key.
  def rotate_to_2!(scope = root)
    Disk::ScopeEpoch.create!(organization: org, scope_node: scope, epoch: 2, previous_key_wrapped: envelope)
    [owner, member].each { |m| key_grant!(scope, m, epoch: 2) if Disk::KeyGrant.exists?(scope_node: scope, membership: m) }
    scope.update!(scope_epoch: 2)
  end

  def reserve(**body)
    post disk_path("/uploads"), params: { parent_id: root.key, size_bytes: 32, sealed: true, chunk_bytes: 1.megabyte,
                                          key_epoch: 1, id: new_id("dnd"), metadata_ciphertext: b64(envelope), **body },
                                headers: owner_h, as: :json
    json["upload"]
  end

  def put_parts(upload, size = 32)
    post disk_path("/uploads/#{upload['id']}/parts"), params: { numbers: [1] }, headers: owner_h, as: :json
    storage.put_part(Disk::Upload.find_by!(key: upload["id"]).multipart_upload_id, 1, size)
  end

  def complete(upload, **body)
    post disk_path("/uploads/#{upload['id']}/complete"), params: { wrapped_key: b64(envelope), manifest_ciphertext: b64(envelope), **body },
                                                         headers: owner_h, as: :json
  end

  it "returns the storage origins in the Disk settings" do
    get disk_path, headers: owner_h
    expect(json["settings"]["storage_origins"]).to eq(["https://storage.test"])
  end

  describe "the epoch rule at each commit point" do
    it "refuses a stale epoch on create, rename, upload reserve and completion" do
      file = make_sealed_file(root)
      upload = reserve
      put_parts(upload)
      rotate_to_2!
      post disk_path("/nodes"), params: { parent_id: root.key, kind: "folder", id: new_id("dnd"), metadata_ciphertext: b64(envelope), key_epoch: 1 },
                                headers: owner_h, as: :json
      expect(response).to have_http_status(:conflict)
      expect(json).to include("code" => "epoch_changed", "current_epoch" => 2)
      patch disk_path("/nodes/#{file.key}"), params: { metadata_ciphertext: b64(envelope), key_epoch: 1 }, headers: owner_h, as: :json
      expect(json["current_epoch"]).to eq(2)
      reserve
      expect(json["current_epoch"]).to eq(2)
      complete(upload)
      expect(json["current_epoch"]).to eq(2)
      expect(Disk::Upload.find_by!(key: upload["id"]).state).to eq("aborted")
      expect(org.reload.disk_bytes_reserved).to eq(0)

      patch disk_path("/nodes/#{file.key}"), params: { metadata_ciphertext: b64(meta = envelope), key_epoch: 2 }, headers: owner_h, as: :json
      expect(response).to have_http_status(:ok)
      expect(file.reload).to have_attributes(metadata_ciphertext: meta, key_epoch: 2)
    end

    it "aborts a completion when a rotation lands just before it takes the scope lock" do
      upload = reserve
      put_parts(upload)
      rotated = false
      allow(Disk::Node).to receive(:lock).and_wrap_original do |original, *args|
        # The rotate commits while the completion waits for the lock on the scope root.
        unless rotated
          rotated = true
          rotate_to_2!
        end
        original.call(*args)
      end
      complete(upload)
      expect(response).to have_http_status(:conflict)
      expect(json["current_epoch"]).to eq(2)
      expect(Disk::Node.where(key: upload["node_id"])).not_to exist
      expect(storage.objects).not_to have_key(Disk::Upload.find_by!(key: upload["id"]).storage_key)
    end

    it "lets only a holder of the current key write" do
      share.share_memberships.create!(organization: org, membership: other, role: "edit") # a role but no key
      post disk_path("/nodes"), params: { parent_id: root.key, kind: "folder", id: new_id("dnd"), metadata_ciphertext: b64(envelope), key_epoch: 1 },
                                headers: auth_headers(other_user), as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "sealed uploads" do
    it "uploads, lists versions with their wrapped fields and presigns sealed thumbnails" do
      upload = reserve(chunk_bytes: 4.megabytes)
      expect(upload).to include("sealed" => true, "key_epoch" => 1, "declared_bytes" => 32)
      put_parts(upload)
      complete(upload, wrapped_key: b64(wk = envelope), manifest_ciphertext: b64(mf = envelope))
      expect(response).to have_http_status(:ok)
      node_id = json["node"]["id"]
      get disk_path("/nodes/#{node_id}/versions"), headers: member_h
      expect(json["versions"].sole).to include("wrapped_key" => b64(wk), "manifest_ciphertext" => b64(mf), "key_epoch" => 1,
                                               "chunk_bytes" => 4.megabytes, "sha256" => nil)
      version_id = json["versions"].sole["id"]
      put disk_path("/versions/#{version_id}/thumbnail"), headers: member_h
      expect(response).to have_http_status(:ok)
      get disk_path("/versions/#{version_id}/download"), headers: member_h
      expect(json["download"]["url"]).not_to include("attachment=#{'x'}")
      expect(json["download"]["url"]).to end_with("attachment=")
    end

    it "refuses sizes that are not whole sealed chunks, a missing id and an unsealed upload into a scope" do
      reserve(size_bytes: 10)
      expect(err).to match(/whole number of sealed chunks/)
      reserve(id: nil)
      expect(err).to match(/21 characters/)
      taken = make_sealed_file(root)
      reserve(id: taken.key)
      expect(response).to have_http_status(:conflict)
      post disk_path("/uploads"), params: { parent_id: root.key, name: "plain.pdf", size_bytes: 3 }, headers: owner_h, as: :json
      expect(err).to match(/sealed/)
    end
  end

  describe "copies and restores" do
    let(:file) { make_sealed_file(root) }
    let(:folder) { make_sealed_node(root) }

    it "copies a sealed file in two steps, invisible until the re-sealed fields arrive" do
      post disk_path("/nodes/#{file.key}/copy"), params: { target_id: folder.key }, headers: member_h, as: :json
      expect(response).to have_http_status(:created)
      upload = json["upload"]
      expect(upload).to include("sealed" => true, "key_epoch" => 1, "declared_bytes" => file.size_bytes)
      expect(upload["node_id"]).not_to eq(file.key)
      expect(Disk::Node.where(key: upload["node_id"])).not_to exist
      stored = Disk::Upload.find_by!(key: upload["id"]).storage_key
      expect(storage.read_range(stored, 0, 8)).to eq(storage.read_range(file.current_version.storage_key, 0, 8))

      post disk_path("/uploads/#{upload['id']}/complete"), params: { wrapped_key: b64(envelope), manifest_ciphertext: b64(envelope) },
                                                           headers: member_h, as: :json
      expect(err).to match(/metadata_ciphertext/)
      post disk_path("/uploads/#{upload['id']}/complete"),
           params: { wrapped_key: b64(envelope), manifest_ciphertext: b64(envelope), metadata_ciphertext: b64(meta = envelope) },
           headers: member_h, as: :json
      expect(response).to have_http_status(:ok)
      copy = Disk::Node.find_by!(key: upload["node_id"])
      expect(copy).to have_attributes(parent_id: folder.id, sealed: true, metadata_ciphertext: meta, seal_scope_node_id: root.id)
      expect(copy.current_version.key).to eq(upload["version_id"])
    end

    it "lets the expiry job drop an unfinished copy with its object" do
      post disk_path("/nodes/#{file.key}/copy"), params: { target_id: folder.key }, headers: member_h, as: :json
      upload = Disk::Upload.find_by!(key: json["upload"]["id"])
      Disk::ExpireUploadsJob.perform_now(now: 2.days.from_now)
      expect(upload.reload.state).to eq("aborted")
      expect(storage.objects).not_to have_key(upload.storage_key)
      expect(org.reload.disk_bytes_reserved).to eq(0)
    end

    it "refuses copies across the seal boundary and of sealed folders" do
      post disk_path("/nodes/#{file.key}/copy"), params: { target_id: c_root(owner).key }, headers: owner_h, as: :json
      expect(json["code"]).to eq("disk_cross_seal")
      plain = make_stored_file(c_root(owner), "a.pdf", size: 3)
      post disk_path("/nodes/#{plain.key}/copy"), params: { target_id: folder.key }, headers: owner_h, as: :json
      expect(json["code"]).to eq("disk_cross_seal")
      post disk_path("/nodes/#{folder.key}/copy"), params: { target_id: root.key }, headers: owner_h, as: :json
      expect(err).to match(/item by item/)
    end

    it "restores an old version as a copy completed under the current epoch" do
      old = file.current_version
      Disk::Node.transaction do
        key = Disk::Storage.new_key(org).tap { |k| storage.put_bytes(k, SecureRandom.random_bytes(48)) }
        file.add_version!(author: owner, storage_key: key, size_bytes: 48, chunk_bytes: 1.megabyte, key_epoch: 1,
                          wrapped_key: envelope, manifest_ciphertext: envelope)
      end
      rotate_to_2!
      post disk_path("/versions/#{old.key}/restore"), headers: member_h
      expect(response).to have_http_status(:created)
      upload = json["upload"]
      expect(upload).to include("node_id" => file.key, "key_epoch" => 2)
      post disk_path("/uploads/#{upload['id']}/complete"), params: { wrapped_key: b64(envelope), manifest_ciphertext: b64(envelope) },
                                                           headers: member_h, as: :json
      expect(response).to have_http_status(:ok)
      expect(file.reload.current_version).to have_attributes(key: upload["version_id"], key_epoch: 2, number: 3)
    end
  end

  describe "moves" do
    let(:file) { make_sealed_file(root) }
    let(:folder) { make_sealed_node(root) }

    it "moves inside a scope with nothing cryptographic, and refuses moves across the seal boundary" do
      post disk_path("/nodes/#{file.key}/move"), params: { target_id: folder.key }, headers: member_h, as: :json
      expect(response).to have_http_status(:ok)
      post disk_path("/nodes/#{file.key}/move"), params: { target_id: c_root(member).key }, headers: member_h, as: :json
      expect(json["code"]).to eq("disk_cross_seal")
      plain = make_folder(c_root(member), "Plain")
      post disk_path("/nodes/#{plain.key}/move"), params: { target_id: folder.key }, headers: member_h, as: :json
      expect(json["code"]).to eq("disk_cross_seal")
    end

    it "moves a sealed C:\\ folder only within its own C:\\" do
      vault = make_sealed_folder(member)
      other_folder = make_folder(c_root(member), "Archive")
      post disk_path("/nodes/#{vault.key}/move"), params: { target_id: other_folder.key }, headers: member_h, as: :json
      expect(response).to have_http_status(:ok)
      open_share = make_share("Open").tap { |s| s.share_memberships.create!(organization: org, membership: member, role: "edit") }
      post disk_path("/nodes/#{vault.key}/move"), params: { target_id: open_share.root_node.key }, headers: member_h, as: :json
      expect(json["code"]).to eq("disk_cross_seal")
      post disk_path("/nodes/#{other_folder.key}/move"), params: { target_id: open_share.root_node.key }, headers: member_h, as: :json
      expect(err).to match(/stays on C:/)
    end

    it "moves a sealed C:\\ folder into a sealed share with every node and version re-wrapped, dropping its scope" do
      vault = make_sealed_folder(member)
      inner = make_sealed_file(vault)
      Disk::Grant.create!(organization: org, node: vault, membership: other, role: "view")
      key_grant!(vault, other)
      link = Disk::Link.create!(organization: org, node: inner, version: inner.current_version, token_digest: "d",
                                kdf_version: 1, kdf_salt: "s" * 16, wrapped_payload: envelope)
      body = { target_id: folder.key, key_epoch: 1,
               nodes: [vault, inner].map { |n| { id: n.key, metadata_ciphertext: b64(envelope) } },
               versions: [{ id: inner.current_version.key, wrapped_key: b64(wk = envelope) }] }
      post disk_path("/nodes/#{vault.key}/move"), params: body.merge(versions: []), headers: member_h, as: :json
      expect(json).to include("missing" => [inner.current_version.key])
      post disk_path("/nodes/#{vault.key}/move"), params: body, headers: member_h, as: :json
      expect(response).to have_http_status(:ok)
      expect(vault.reload).to have_attributes(seal_scope_node_id: root.id, share_id: share.id, custodian_membership_id: nil,
                                              parent_id: folder.id, scope_epoch: nil)
      expect(inner.reload).to have_attributes(seal_scope_node_id: root.id, share_id: share.id)
      expect(inner.current_version.wrapped_key).to eq(wk)
      expect(Disk::KeyGrant.where(scope_node_id: vault.id)).not_to exist
      expect(Disk::Grant.where(node_id: vault.id)).not_to exist
      expect(link.reload.revoked_at).to be_present
      expect(json["revoked"]["links"]).to eq([link.key])
    end

    it "refuses a stale epoch on a move into another scope" do
      vault = make_sealed_folder(member)
      rotate_to_2!
      post disk_path("/nodes/#{vault.key}/move"),
           params: { target_id: folder.key, key_epoch: 1, nodes: [{ id: vault.key, metadata_ciphertext: b64(envelope) }], versions: [] },
           headers: member_h, as: :json
      expect(json).to include("code" => "epoch_changed", "current_epoch" => 2)
    end
  end

  describe "the staged switch across the seal boundary" do
    let(:plain) { make_stored_file(c_root(owner), "secret-plan.pdf", size: 3) }

    it "stages a sealed copy, switches it in and purges the plaintext source and its versions" do
      Disk::Link.create!(organization: org, node: plain, token_digest: "t1")
      source_key = plain.current_version.storage_key
      upload = reserve(staged: true)
      put_parts(upload)
      complete(upload)
      staged = json["node"]["id"]
      get disk_path("/nodes/#{root.key}/children"), headers: member_h
      expect(json["nodes"].pluck("id")).not_to include(staged)
      get disk_path("/nodes/#{staged}"), headers: member_h
      expect(response).to have_http_status(:not_found)

      post disk_path("/nodes/#{plain.key}/switch"), params: { staged_id: staged }, headers: owner_h, as: :json
      expect(response).to have_http_status(:ok)
      expect(json["node"]["id"]).to eq(staged)
      expect(json["revoked"]["links"].size).to eq(1)
      expect(Disk::Node.exists?(plain.id)).to be(false)
      expect(storage.objects).not_to have_key(source_key)
      get disk_path("/nodes/#{staged}"), headers: member_h
      expect(response).to have_http_status(:ok)
    end

    it "needs manage to unseal, finishes interrupted purges in the job, and lets a failed stage be purged" do
      sealed = make_sealed_file(root)
      post disk_path("/uploads"), params: { parent_id: c_root(member).key, name: "out.pdf", size_bytes: 3, staged: true },
                                  headers: member_h, as: :json
      upload = json["upload"]
      post disk_path("/uploads/#{upload['id']}/parts"), params: { numbers: [1] }, headers: member_h, as: :json
      storage.put_part(Disk::Upload.find_by!(key: upload["id"]).multipart_upload_id, 1, 3)
      post disk_path("/uploads/#{upload['id']}/complete"), headers: member_h, as: :json
      staged = json["node"]["id"]
      post disk_path("/nodes/#{sealed.key}/switch"), params: { staged_id: staged }, headers: member_h, as: :json
      expect(response).to have_http_status(:forbidden)

      allow(Disk::NodeOps).to receive(:purge!).and_raise(ActiveRecord::StatementTimeout)
      share.share_memberships.find_by!(membership: member).update!(role: "manage")
      post disk_path("/nodes/#{sealed.key}/switch"), params: { staged_id: staged }, headers: member_h, as: :json
      expect(response).to have_http_status(:ok)
      expect(sealed.reload.switched_at).to be_present
      get disk_path("/nodes/#{sealed.key}"), headers: member_h
      expect(response).to have_http_status(:not_found)
      allow(Disk::NodeOps).to receive(:purge!).and_call_original
      Disk::ExpireUploadsJob.perform_now
      expect(Disk::Node.exists?(sealed.id)).to be(false)

      upload = reserve(staged: true)
      put_parts(upload)
      complete(upload)
      delete disk_path("/nodes/#{json['node']['id']}/purge"), headers: owner_h
      expect(response).to have_http_status(:no_content)
      post disk_path("/nodes/#{plain.key}/switch"), params: { staged_id: new_id("dnd") }, headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)
      post disk_path("/nodes/#{foreign_node.key}/switch"), params: { staged_id: new_id("dnd") }, headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "sealed file links" do
    let(:file) { make_sealed_file(root) }
    let(:verifier) { SecureRandom.random_bytes(32) }

    def create_link(**body)
      post disk_path("/nodes/#{file.key}/links"),
           params: { id: new_id("dln"), version_id: file.current_version.key, kdf_salt: b64("s" * 16),
                     wrapped_payload: b64(envelope), **body }, headers: owner_h, as: :json
      json["link"]
    end

    def pub(token, path = "") = "/api/v1/disk/links/#{token}#{path}"

    it "makes a nameless link pinned to a version and serves its payload after the verifier" do
      link = create_link(password_verifier: b64(verifier))
      expect(response).to have_http_status(:created)
      expect(link["url"]).to match(%r{/share/[A-Za-z0-9]{22}\z})
      expect(link).to include("sealed" => true, "version_id" => file.current_version.key, "has_password" => true)
      stored = Disk::Link.find_by!(key: link["id"])
      expect(stored.password_verifier_digest).to eq(Digest::SHA256.hexdigest(verifier))

      get pub(link["token"])
      expect(json["link"]).to include("sealed" => true, "kdf_version" => 1, "kdf_salt" => b64("s" * 16),
                                      "unlocked" => false, "sealed_payload" => nil)
      post pub(link["token"], "/unlock"), params: { verifier: b64(SecureRandom.random_bytes(32)) }, as: :json
      expect(response).to have_http_status(:forbidden)
      post pub(link["token"], "/unlock"), params: { verifier: b64(verifier) }, as: :json
      unlock = json["unlock"]["token"]
      get pub(link["token"]), headers: { "X-Disk-Link-Unlock" => unlock }
      expect(json["link"]["sealed_payload"]).to include("link_id" => link["id"], "version_id" => file.current_version.key,
                                                        "wrapped_payload" => b64(stored.wrapped_payload),
                                                        "manifest_ciphertext" => b64(file.current_version.manifest_ciphertext))
      expect(json["link"]["node"]).to include("name" => nil, "mime" => nil)
      get pub(link["token"], "/download"), headers: { "X-Disk-Link-Unlock" => unlock }
      expect(json["download"]["url"]).to eq("https://storage.test/#{file.current_version.storage_key}?attachment=")
    end

    it "serves a link without a password at once, pinned even after a new version" do
      link = create_link
      pinned = file.current_version
      Disk::Node.transaction do
        file.add_version!(author: owner, storage_key: Disk::Storage.new_key(org).tap { |k| storage.put(k, 48) }, size_bytes: 48,
                          chunk_bytes: 1.megabyte, key_epoch: 1, wrapped_key: envelope, manifest_ciphertext: envelope)
      end
      get pub(link["token"])
      expect(json["link"]["sealed_payload"]["version_id"]).to eq(pinned.key)
      get pub(link["token"], "/download")
      expect(json["download"]["preview_url"]).to include(pinned.storage_key)
    end

    it "refuses folders, foreign versions, bad salts and taken ids" do
      post disk_path("/nodes/#{make_sealed_node(root).key}/links"), params: { id: new_id("dln") }, headers: owner_h, as: :json
      expect(err).to match(/no public links/)
      create_link(version_id: make_sealed_file(root).current_version.key)
      expect(err).to match(/version_id/)
      create_link(kdf_salt: b64("short"))
      expect(err).to match(/kdf_salt/)
      taken = create_link
      create_link(id: taken["id"])
      expect(response).to have_http_status(:conflict)
      post disk_path("/nodes/#{file.key}/links"), params: { id: new_id("dln") }, headers: member_h, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "refuses a new link while the scope's rotation is due, and from a manager holding no key" do
      file
      root.update!(rotation_due: true)
      create_link
      expect(response).to have_http_status(:conflict)
      expect(json).to include("code" => "rotation_required")
      root.update!(rotation_due: false)
      Disk::KeyGrant.where(scope_node_id: root.id, membership_id: owner.id).delete_all
      create_link
      expect(response).to have_http_status(:forbidden)
      expect(Disk::Link.where(node_id: file.id)).to be_empty
    end

    it "rate limits wrong verifiers per link" do
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      token = create_link(password_verifier: b64(verifier))["token"]
      statuses = Array.new(11) do
        post pub(token, "/unlock"), params: { verifier: b64(SecureRandom.random_bytes(32)) }, as: :json
        response.status
      end
      expect(statuses.first(10).uniq).to eq([403])
      expect(statuses.last).to eq(429)
    ensure
      Rack::Attack.cache.store = Rails.cache
    end
  end

  describe "sealed pages" do
    let(:page) { make_sealed_node(root, kind: Disk::Node::KIND_PAGE) }

    def append(seq, epoch: 1, headers: member_h, update: b64(envelope))
      post disk_path("/pages/#{page.key}/updates"), params: { update: update, epoch: epoch, seq: seq }, headers: headers, as: :json
    end

    def snapshot(seq, epoch: 1, bytes: envelope(200))
      put disk_path("/pages/#{page.key}"), params: { sealed_snapshot: b64(bytes), epoch: epoch, seq: seq }, headers: member_h, as: :json
    end

    it "takes updates only at update_seq + 1, relaying each after it is stored" do
      expect { append(1) }.to have_broadcasted_to(page).from_channel(DiskPageChannel).with(hash_including("type" => "sealed_update", "seq" => 1, "epoch" => 1))
      expect(response).to have_http_status(:created)
      append(1, headers: owner_h) # a second writer at the same seq
      expect(response).to have_http_status(:conflict)
      expect(json).to include("update_seq" => 1, "current_epoch" => 1)
      expect { append(3) }.not_to have_broadcasted_to(page).from_channel(DiskPageChannel)
      expect(json["update_seq"]).to eq(1)
      append(2)
      expect(Disk::Page.for(page).update_seq).to eq(2)
      post disk_path("/pages/#{foreign_node.key}/updates"), params: { update: b64(envelope), epoch: 1, seq: 1 }, headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)
      post disk_path("/pages/#{make_sealed_node(root).key}/updates"), params: { update: b64(envelope), epoch: 1, seq: 1 }, headers: owner_h, as: :json
      expect(err).to match(/not a page/)
      expect(Disk::PageUpdate.where(node: page).pluck(:seq)).to eq([1, 2])
    end

    it "refuses an old-epoch update and changes nothing" do
      append(1)
      rotate_to_2!
      expect { append(2, epoch: 1) }.not_to have_broadcasted_to(page).from_channel(DiskPageChannel)
      expect(json).to include("code" => "epoch_changed", "current_epoch" => 2)
      expect(Disk::Page.for(page).update_seq).to eq(1)
      append(2, epoch: 2)
      expect(response).to have_http_status(:created)
    end

    it "saves snapshots, drops the updates they cover and serves a joining client the rest" do
      3.times { |i| append(i + 1) }
      snapshot(2, bytes: snap = envelope(300))
      expect(response).to have_http_status(:ok)
      expect(json["page"]).to include("snapshot_seq" => 2, "snapshot_epoch" => 1, "update_seq" => 3, "markdown" => nil)
      expect(Disk::PageUpdate.where(node: page).pluck(:seq)).to eq([3])
      expect(page.reload.size_bytes).to eq(300)
      get disk_path("/pages/#{page.key}"), headers: owner_h
      expect(json["page"]).to include("sealed" => true, "sealed_snapshot" => b64(snap), "ydoc" => nil)
      expect(json["page"]["updates"].pluck("seq")).to eq([3])
      snapshot(1)
      expect(response).to have_http_status(:conflict)
      snapshot(4)
      expect(response).to have_http_status(:conflict)
      get disk_path("/pages/#{page.key}/versions"), headers: owner_h
      expect(json["versions"].first).to include("snapshot_seq" => 2, "markdown" => nil)
    end

    it "lists sealed pages as encrypted and skipped in the org export" do
      snapshot(0)
      get disk_path("/admin/export"), headers: owner_h
      entry = json["export"]["entries"].find { |e| e["id"] == page.key }
      expect(entry).to include("sealed" => true, "included" => false, "markdown" => nil, "url" => nil)
    end
  end
end
