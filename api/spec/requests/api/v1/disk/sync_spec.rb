require "rails_helper"

# The Disk sync feed (docs/Disk-Sync.md). Like spec/requests/api/v1/sync_spec.rb,
# the request shares the test's transaction, which is the "own writes are
# visible" branch of the horizon filter.
RSpec.describe "Api::V1::Disk::Sync", type: :request do
  include_context "disk org"

  let(:owner_h) { auth_headers(owner_user) }
  let(:member_h) { auth_headers(member_user) }
  let(:share) { make_share("Marketing") }
  let(:root) { share.root_node }

  def join(role, who = member, to: share) = Disk::ShareMembership.create!(organization: org, share: to, membership: who, role: role)

  def pull(since: nil, limit: nil, headers: member_h)
    get disk_path("/sync/pull"), params: { since: since, limit: limit }.compact, headers: headers
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  def keys(headers: member_h, after: nil)
    get disk_path("/sync/keys"), params: { after: after }.compact, headers: headers
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  def ids(data) = data["nodes"].map { |n| n["id"] }

  def pull_all(since: nil, limit: nil, headers: member_h)
    seen = { "nodes" => [], "deleted" => [], "reconcile" => false }
    loop do
      data = pull(since: since, limit: limit, headers: headers)
      seen["nodes"].concat(ids(data))
      seen["deleted"].concat(data["deleted"])
      seen["reconcile"] ||= data["reconcile"]
      since = data["cursor"]
      return [seen, since] unless data["has_more"]
    end
  end

  describe "GET disk/sync/head" do
    it "returns a cursor that a pull starts from" do
      get disk_path("/sync/head"), headers: member_h
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["cursor"]).to match(/\A\d+\.0\z/)
    end

    it "404s an org the person is not in" do
      get "/api/v1/orgs/#{outsider_org.key}/disk/sync/head", headers: member_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET disk/sync/pull" do
    it "returns changed nodes in the sync shape, then nothing on the returned cursor" do
      join("edit")
      folder = make_folder(root, "Launch")
      file = make_stored_file(folder, "deck.pdf", size: 5)
      mine = make_folder(c_root(member), "Notes")

      data = pull
      expect(ids(data)).to include(root.key, folder.key, file.key, mine.key, c_root(member).key)
      # (A first pull also walks the "acl" events of setting the share up, so reconcile may be set.)
      expect(data).to include("has_more" => false, "cursor_expired" => false, "deleted" => [])
      by_id = data["nodes"].index_by { |n| n["id"] }
      expect(by_id[root.key]).to include("parent_id" => nil, "drive" => share.key, "share_name" => "Marketing",
                                         "kind" => "folder", "can_write" => true)
      expect(by_id[file.key]).to include("parent_id" => folder.key, "drive" => share.key, "share_name" => nil,
                                         "name" => "deck.pdf", "mime" => "application/pdf", "sealed" => false,
                                         "metadata_ciphertext" => nil, "seal_scope_id" => nil, "size_bytes" => 5)
      expect(by_id[file.key]["change_seq"]).to be > 0
      expect(by_id[file.key]["current_version"]).to include("id" => file.current_version.key, "size_bytes" => 5)
      expect(by_id[file.key]["current_version"]).not_to have_key("wrapped_key")
      expect(by_id[mine.key]).to include("drive" => "c", "parent_id" => c_root(member).key)
      expect(data.to_json).not_to match(/"(organization_id|change_xid|custodian_membership_id)"/) # E4/E5

      again = pull(since: data["cursor"])
      expect(again).to include("nodes" => [], "deleted" => [], "has_more" => false, "reconcile" => false)
    end

    it "sees renames and update_all writes" do
      join("view")
      file = make_stored_file(root, "a.pdf", size: 1)
      cursor = pull["cursor"]

      Disk::Node.where(id: file.id).update_all(name: "b.pdf")
      data = pull(since: cursor)
      expect(data["nodes"].map { |n| [n["id"], n["name"], n["can_write"]] }).to eq([[file.key, "b.pdf", false]])
    end

    it "pages with has_more and a cursor that picks up where it stopped" do
      join("view")
      folders = 5.times.map { |i| make_folder(root, "F#{i}") }
      first = pull(limit: 2)
      expect(first["has_more"]).to be true
      expect(first["nodes"].size).to be <= 2 # "acl" events take places in a page too

      seen, = pull_all(limit: 2)
      expect(seen["nodes"]).to include(*folders.map(&:key), root.key)
      expect(seen["nodes"].tally.values.max).to eq(1)
    end

    it "hands out sealed nodes without a name" do
      sealed = make_sealed_share("Vault", holders: { member => "edit" })
      file = make_sealed_file(make_sealed_node(sealed.root_node))
      data = pull
      node = data["nodes"].find { |n| n["id"] == file.key }
      expect(node).to include("name" => nil, "mime" => nil, "sealed" => true, "key_epoch" => 1,
                              "seal_scope_id" => sealed.root_node.key,
                              "metadata_ciphertext" => b64(file.metadata_ciphertext))
      expect(node["current_version"]).to include("chunk_bytes" => 1.megabyte, "key_epoch" => 1,
                                                 "wrapped_key" => b64(file.current_version.wrapped_key),
                                                 "manifest_ciphertext" => b64(file.current_version.manifest_ciphertext))
      root_row = data["nodes"].find { |n| n["id"] == sealed.root_node.key }
      expect(root_row["share_name"]).to eq("Vault")
    end

    it "reports trashed and purged nodes in deleted" do
      join("edit")
      a = make_stored_file(root, "a.pdf", size: 1)
      b = make_stored_file(root, "b.pdf", size: 1)
      cursor = pull["cursor"]

      delete disk_path("/nodes/#{a.key}"), headers: member_h
      expect(response).to have_http_status(:ok)
      data = pull(since: cursor)
      expect(data["deleted"]).to eq([a.key])
      expect(ids(data)).to eq([root.key]) # its size went down

      cursor = data["cursor"]
      delete disk_path("/nodes/#{b.key}"), headers: member_h
      delete disk_path("/nodes/#{b.key}/purge"), headers: member_h
      expect(response).to have_http_status(:success)
      expect(Disk::Node.where(id: b.id)).not_to exist
      expect(pull(since: cursor)["deleted"]).to eq([b.key])
    end

    it "reports a node moved out of view in deleted, and one moved into view with its contents" do
      seen = make_folder(root, "Seen")
      hidden = make_folder(root, "Hidden")
      leaving = make_folder(seen, "Leaving")
      arriving = make_folder(hidden, "Arriving")
      inside = make_stored_file(arriving, "inside.pdf", size: 1)
      Disk::Grant.create!(organization: org, node: seen, membership: member, role: "view")
      cursor = pull["cursor"]

      post disk_path("/nodes/#{leaving.key}/move"), params: { target_id: hidden.key }, headers: owner_h, as: :json
      expect(response).to have_http_status(:ok)
      post disk_path("/nodes/#{arriving.key}/move"), params: { target_id: seen.key }, headers: owner_h, as: :json
      expect(response).to have_http_status(:ok)

      data, = pull_all(since: cursor)
      # Hidden and the share root changed size: changed nodes the member cannot see come back as deleted too.
      expect(data["deleted"]).to contain_exactly(leaving.key, hidden.key, root.key)
      expect(data["nodes"]).to include(arriving.key, inside.key)
    end

    it "reports a file that left the team for the mover's C:\\ to everyone else in deleted" do
      open_share = make_share("Open", openness: "org", org_role: "edit")
      file = make_stored_file(open_share.root_node, "deal.pdf", size: 1)
      cursor = pull(headers: auth_headers(other_user))["cursor"]

      post disk_path("/nodes/#{file.key}/move"), params: { target_id: c_root(member).key }, headers: member_h, as: :json
      expect(response).to have_http_status(:ok)
      expect(pull(since: cursor, headers: auth_headers(other_user))["deleted"]).to eq([file.key])
    end

    it "sets reconcile when a share membership goes, and keys stop listing what it reached" do
      join("view")
      file = make_stored_file(root, "a.pdf", size: 1)
      expect(keys["keys"].map(&:first)).to include(file.key)
      cursor = pull["cursor"]

      delete disk_path("/shares/#{share.key}/members/#{member.key}"), headers: owner_h
      expect(response).to have_http_status(:success)
      data = pull(since: cursor)
      expect(data["reconcile"]).to be true
      expect(keys["keys"].map(&:first)).not_to include(file.key, root.key)
    end

    it "sets reconcile when a grant is revoked" do
      folder = make_folder(root, "Brief")
      Disk::Grant.create!(organization: org, node: folder, membership: member, role: "edit")
      expect(keys["keys"].map(&:first)).to eq([folder.key])
      cursor = pull["cursor"]

      delete disk_path("/nodes/#{folder.key}/grants/#{member.key}"), headers: owner_h
      expect(response).to have_http_status(:success)
      expect(pull(since: cursor)["reconcile"]).to be true
      expect(keys["keys"]).to be_empty
    end

    it "sees a grant on another person's C:\\, and its revocation" do
      theirs = make_folder(c_root(other), "For Mo")
      cursor = pull["cursor"]
      Disk::Grant.create!(organization_id: theirs.organization_id, node: theirs, membership: member, role: "view")
      expect(pull(since: cursor)["reconcile"]).to be true

      cursor = pull["cursor"]
      theirs.update!(name: "For Mo v2")
      data = pull(since: cursor)
      expect(data["nodes"].map { |n| [n["id"], n["name"], n["drive"]] }).to eq([[theirs.key, "For Mo v2", "shared"]])

      Disk::Grant.where(node: theirs).delete_all
      expect(pull(since: data["cursor"])["reconcile"]).to be true
    end

    it "never shows another org's nodes" do
      join("view")
      foreign_node
      data, = pull_all
      expect(data["nodes"]).not_to include(foreign_node.key, foreign_share.root_node.key)
      expect(data["deleted"]).not_to include(foreign_node.key)
    end

    it "flags a cursor older than the pruned-event watermark, and one from another database" do
      cursor = pull["cursor"]
      xid = cursor.split(".").first.to_i
      Disk::SyncEvent.create!(organization_id: org.id, kind: "acl", change_seq: 1, change_xid: xid + 5,
                              created_at: 40.days.ago)
      expect(pull(since: cursor)).to include("cursor_expired" => true, "reconcile" => true)
      expect(pull["cursor_expired"]).to be false

      data = pull(since: "999999999999.0")
      expect(data["cursor_expired"]).to be true
      expect(data["cursor"].split(".").first.to_i).to be < 999_999_999_999
    end

    it "rejects a malformed cursor" do
      get disk_path("/sync/pull"), params: { since: "yesterday" }, headers: member_h
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET disk/sync/keys" do
    it "lists every live, visible, non-staged node with its version, paged by key" do
      join("view")
      file = make_stored_file(root, "a.pdf", size: 1)
      trashed = make_folder(root, "Old", trashed_at: Time.current)
      staged = make_folder(root, "Staged", pending_until: 1.hour.from_now, created_by: member)
      foreign_node

      listed = keys["keys"].to_h
      expect(listed.keys).to include(file.key, root.key)
      expect(listed.keys).not_to include(trashed.key, staged.key, foreign_node.key)
      expect(listed[file.key]).to eq(file.reload.change_seq)

      stub_const("Api::V1::Disk::SyncController::KEYS_LIMIT", 1)
      page = keys
      expect(page["keys"].size).to eq(1)
      expect(page["next"]).to eq(page["keys"][0][0])
      walked = [page["keys"][0][0]]
      walked << (page = keys(after: page["next"]))["keys"][0][0] while page["next"]
      expect(walked).to match_array(listed.keys)
    end

    it "404s an org the person is not in" do
      get "/api/v1/orgs/#{outsider_org.key}/disk/sync/keys", headers: member_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET disk/sync/nodes" do
    it "hydrates visible nodes and names the rest missing" do
      join("view")
      file = make_stored_file(root, "a.pdf", size: 1)
      hidden = make_folder(make_share("Board").root_node, "Minutes")
      get disk_path("/sync/nodes"), params: { ids: [file.key, hidden.key, foreign_node.key, "dnd_nope"] }, headers: member_h
      expect(response).to have_http_status(:ok)
      expect(ids(response.parsed_body)).to eq([file.key])
      expect(response.parsed_body["missing"]).to contain_exactly(hidden.key, foreign_node.key, "dnd_nope")
    end

    it "refuses more than 200 ids" do
      get disk_path("/sync/nodes"), params: { ids: 201.times.map { |i| "dnd_#{i}" } }, headers: member_h
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "uploads from a mirror" do
    def reserve(size, **body)
      post disk_path("/uploads"), params: { size_bytes: size, **body }, headers: owner_h, as: :json
      response.parsed_body["upload"]
    end

    def put_and_complete(upload, size, **body)
      post disk_path("/uploads/#{upload['id']}/parts"), params: { numbers: [1] }, headers: owner_h, as: :json
      storage.put_part(Disk::Upload.find_by!(key: upload["id"]).multipart_upload_id, 1, size)
      complete(upload, **body)
    end

    def complete(upload, **body)
      post disk_path("/uploads/#{upload['id']}/complete"), params: body, headers: owner_h, as: :json
    end

    let(:file) { make_stored_file(root, "a.pdf", size: 5) }

    it "adds the version when base_version is still current" do
      base = file.current_version.key
      put_and_complete(reserve(3, node_id: file.key, base_version: base), 3)
      expect(response).to have_http_status(:ok)
      expect(file.reload.versions.count).to eq(2)
    end

    it "answers 409 version_conflict when the file moved on, keeping the upload to retry" do
      stale = file.current_version.key
      upload = reserve(3, node_id: file.key, base_version: stale)
      Disk::UploadOps.new(owner).write(bytes: "new", node_key: file.key) # someone else saved first
      current = file.reload.current_version.key

      put_and_complete(upload, 3)
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to include("code" => "version_conflict", "current_version_id" => current)
      expect(file.reload.versions.count).to eq(2)
      expect(Disk::Upload.find_by!(key: upload["id"]).state).to eq("reserved")

      complete(upload, base_version: current) # overwrite on purpose
      expect(response).to have_http_status(:ok)
      expect(file.reload.current_version.key).to eq(upload["version_id"])
    end

    it "takes \"none\" as the base of a file that had no version, and refuses it once one exists" do
      file.update_columns(current_version_id: nil)
      put_and_complete(reserve(3, node_id: file.key, base_version: Disk::Upload::NO_VERSION), 3)
      expect(response).to have_http_status(:ok)

      put_and_complete(reserve(4, node_id: file.key, base_version: Disk::Upload::NO_VERSION, idempotency_key: "again"), 4)
      expect(response).to have_http_status(:conflict)
    end

    it "checks base_version given at completion" do
      upload = reserve(3, node_id: file.key)
      put_and_complete(upload, 3, base_version: "dvr_somethingelse")
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["code"]).to eq("version_conflict")
    end

    it "answers a repeated completion with the same node and version, never a second version" do
      upload = reserve(3, node_id: file.key, base_version: file.current_version.key)
      put_and_complete(upload, 3)
      first = response.parsed_body
      complete(upload, base_version: "dvr_stale_now")
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["version"]["id"]).to eq(first["version"]["id"])
      expect(response.parsed_body["node"]["id"]).to eq(file.key)
      expect(file.reload.versions.count).to eq(2)
    end

    it "keeps the web client's behaviour without base_version" do
      upload = reserve(3, node_id: file.key)
      Disk::UploadOps.new(owner).write(bytes: "new", node_key: file.key)
      put_and_complete(upload, 3)
      expect(response).to have_http_status(:ok)
      expect(file.reload.versions.count).to eq(3)
    end
  end

  # Finder's "Copy inbox2 link" (docs/Disk-Sync.md).
  describe "GET disk/nodes/:id/link" do
    it "gives the web app link as the member reaches the item" do
      join("view")
      file = make_file(make_folder(root, "Brand"), "Logo.png", mime: "image/png")
      get disk_path("/nodes/#{file.key}/link"), headers: member_h
      expect(response).to have_http_status(:ok)
      url = response.parsed_body.dig("link", "url")
      expect(url).to end_with("/disk/d/#{share.slug}/Brand/Logo.png-#{file.short_id}")
    end

    it "is not found for an item the member cannot see (E3)" do
      file = make_file(root, "Plan.pdf", mime: "application/pdf")
      get disk_path("/nodes/#{file.key}/link"), headers: member_h
      expect(response).to have_http_status(:not_found)
      get disk_path("/nodes/#{foreign_node.key}/link"), headers: owner_h
      expect(response).to have_http_status(:not_found)
    end
  end

  # Disk writes tell the org's devices to pull, so Finder updates within seconds.
  describe "the disk change signal" do
    before { Api::V1::BaseController::SYNC_HINT_SENT.clear }

    it "broadcasts scope disk after a Disk write" do
      expect {
        post disk_path("/nodes"), params: { parent_id: root.key, name: "New" }, headers: owner_h, as: :json
      }.to have_broadcasted_to("organization_#{org.key}").with(type: "sync", scope: "disk")
      expect(response).to have_http_status(:created)
    end

    it "sends nothing for a read" do
      expect { pull(headers: owner_h) }.not_to have_broadcasted_to("organization_#{org.key}")
    end
  end
end
