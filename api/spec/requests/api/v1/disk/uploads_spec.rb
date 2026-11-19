require "rails_helper"

# Spec F2 (uploads, quota reservation, cleanup), F8 (meter moves, refused up
# front) and the upload protocol in docs/plans/disk-build.md section 8.
RSpec.describe "Api::V1::Disk::Uploads", type: :request do
  include_context "disk org"

  let(:owner_h) { auth_headers(owner_user) }
  let(:member_h) { auth_headers(member_user) }
  let(:share) { make_share("Marketing") }
  let(:root) { share.root_node }
  let(:mib) { 1.megabyte }

  def join(role, who = member) = Disk::ShareMembership.create!(organization: org, share: share, membership: who, role: role)

  def reserve(size, headers: owner_h, **body)
    post disk_path("/uploads"), params: { parent_id: root.key, name: "a.pdf", size_bytes: size, **body },
                                headers: headers, as: :json
    response.parsed_body["upload"]
  end

  def issue(upload, numbers, headers: owner_h)
    post disk_path("/uploads/#{upload['id']}/parts"), params: { numbers: numbers }, headers: headers, as: :json
  end

  def complete(upload, headers: owner_h, **body)
    post disk_path("/uploads/#{upload['id']}/complete"), params: body, headers: headers, as: :json
  end

  def multipart_id(upload) = Disk::Upload.find_by!(key: upload["id"]).multipart_upload_id

  # Reserve, upload every part through the fake, complete.
  def upload_file(size, sha256: nil, **body)
    upload = reserve(size, **body)
    count = upload["part_count"]
    issue(upload, (1..count).to_a) if count.positive?
    (1..count).each do |n|
      storage.put_part(multipart_id(upload), n, n == count ? size - (upload["part_bytes"] * (count - 1)) : upload["part_bytes"])
    end
    complete(upload, **{ sha256: sha256 }.compact)
    response.parsed_body
  end

  describe "POST /uploads" do
    it "reserves quota, fixes the part size and hands out the ids the file will have" do
      upload = reserve(20 * mib, idempotency_key: "k1")
      expect(response).to have_http_status(:created)
      expect(upload).to include("state" => "reserved", "declared_bytes" => 20 * mib, "part_bytes" => 8 * mib,
                                "part_count" => 3, "parent_id" => root.key, "sealed" => false)
      expect(upload["node_id"]).to start_with("dnd_")
      expect(upload["version_id"]).to start_with("dvr_")
      expect(org.reload.disk_bytes_reserved).to eq(20 * mib)
      expect(storage.multiparts.size).to eq(1)
    end

    it "returns the same upload for the same idempotency key" do
      first = reserve(10, idempotency_key: "same")
      second = reserve(10, idempotency_key: "same")
      expect(response).to have_http_status(:ok)
      expect(second["id"]).to eq(first["id"])
      expect(org.reload.disk_bytes_reserved).to eq(10)
    end

    it "refuses over quota with a quota error and stores nothing" do
      org.update!(disk_quota_override_gb: 1, disk_bytes_used: 1.gigabyte - 5)
      reserve(10)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["code"]).to eq("disk_quota_exceeded")
      expect(Disk::Upload.count).to eq(0)
      expect(storage.multiparts).to be_empty
      expect(org.reload.disk_bytes_reserved).to eq(0)
    end

    it "does not let two uploads that jointly exceed the quota both reserve" do
      org.update!(disk_quota_override_gb: 1)
      reserve(600 * mib)
      expect(response).to have_http_status(:created)
      reserve(600 * mib, name: "b.pdf")
      expect(response).to have_http_status(:unprocessable_content)
      expect(org.reload.disk_bytes_reserved).to eq(600 * mib)
    end

    it "asks keep both or replace on a name clash" do
      make_stored_file(root, "a.pdf", size: 5)
      reserve(10)
      expect(response).to have_http_status(:conflict)
    end

    it "refuses a viewer, a bad name and a sealed upload into an unsealed folder" do
      join("view")
      reserve(10, headers: member_h)
      expect(response).to have_http_status(:forbidden)
      reserve(10, name: "a/b")
      expect(response).to have_http_status(:unprocessable_content)
      reserve(10, sealed: true, chunk_bytes: 4 * mib, key_epoch: 1, metadata_ciphertext: Base64.strict_encode64("x"))
      expect(response.parsed_body["errors"].first["message"]).to eq("Only a sealed folder takes sealed uploads")
      expect(Disk::Upload.count).to eq(0)
    end

    it "404s another org's folder" do
      post disk_path("/uploads"), params: { parent_id: foreign_node.key, name: "a.pdf", size_bytes: 1 },
                                  headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /uploads/:id/parts" do
    it "presigns the requested parts and records each as issued" do
      upload = reserve(20 * mib)
      issue(upload, [1, 3])
      expect(response).to have_http_status(:ok)
      parts = response.parsed_body["parts"]
      expect(parts.map { |p| p["number"] }).to eq([1, 3])
      expect(parts.first["url"]).to include("partNumber=1")
      expect(parts.first["expires_at"]).to be_present
      expect(Disk::UploadPart.pluck(:number)).to contain_exactly(1, 3)
    end

    it "refuses part numbers outside the upload" do
      upload = reserve(20 * mib)
      issue(upload, [4])
      expect(response).to have_http_status(:unprocessable_content)
      issue(upload, [])
      expect(response).to have_http_status(:bad_request).or have_http_status(:unprocessable_content)
    end

    it "404s another member's upload and another org's" do
      upload = reserve(10)
      issue(upload, [1], headers: member_h)
      expect(response).to have_http_status(:not_found)
      post "/api/v1/orgs/#{outsider_org.key}/disk/uploads/#{upload['id']}/parts", params: { numbers: [1] },
                                                                                 headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /uploads/:id/complete" do
    it "creates the file and its version, settles the quota and rolls the size up the folders" do
      folder = make_folder(root, "Launch")
      body = nil
      expect do
        body = upload_file(20 * mib, parent_id: folder.key, name: "deck.pdf", sha256: "a" * 64)
      end.to change { org.reload.disk_bytes_used }.by(20 * mib)
      expect(response).to have_http_status(:ok)
      expect(body["node"]).to include("name" => "deck.pdf", "mime" => "application/pdf", "size_bytes" => 20 * mib,
                                      "current_version_id" => body["version"]["id"])
      expect(body["version"]).to include("number" => 1, "size_bytes" => 20 * mib, "sha256" => "a" * 64, "current" => true)
      expect(org.reload.disk_bytes_reserved).to eq(0)
      expect(folder.reload.size_bytes).to eq(20 * mib)
      expect(root.reload.size_bytes).to eq(20 * mib)
      expect(Disk::Event.last).to have_attributes(action: "uploaded")
      get disk_path("/"), headers: owner_h
      expect(response.parsed_body["quota"]).to include("used_bytes" => 20 * mib, "files_bytes" => 20 * mib)
    end

    it "uses the ids handed out at reserve time and is idempotent" do
      upload = reserve(10)
      issue(upload, [1])
      storage.put_part(multipart_id(upload), 1, 10)
      complete(upload)
      first = response.parsed_body
      expect(first["node"]["id"]).to eq(upload["node_id"])
      expect(first["version"]["id"]).to eq(upload["version_id"])
      complete(upload)
      expect(response.parsed_body["version"]["id"]).to eq(first["version"]["id"])
      expect(Disk::Version.count).to eq(1)
    end

    it "stores an empty file without parts" do
      body = upload_file(0, name: "empty.txt")
      expect(response).to have_http_status(:ok)
      expect(body["node"]).to include("name" => "empty.txt", "size_bytes" => 0)
    end

    it "replaces as a new version, or keeps both as a (1)" do
      original = make_stored_file(root, "a.pdf", size: 5)
      upload_file(7, on_conflict: "replace")
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["node"]["id"]).to eq(original.key)
      expect(original.reload.versions.order(:number).pluck(:number, :size_bytes)).to eq([[1, 5], [2, 7]])
      expect(original.versions.find_by(number: 1).expires_at).to be_within(1.minute).of(180.days.from_now)
      expect(root.reload.size_bytes).to eq(7)
      expect(Disk::Event.last).to have_attributes(action: "version_added")

      upload_file(3, on_conflict: "keep_both")
      expect(response.parsed_body["node"]["name"]).to eq("a (1).pdf")
      expect(org.reload.disk_bytes_used).to eq(15)
    end

    it "replacing twice gives three versions, and restoring the first makes a fourth (spec F2)" do
      upload_file(1, name: "r.pdf")
      upload_file(2, name: "r.pdf", on_conflict: "replace")
      upload_file(3, name: "r.pdf", on_conflict: "replace")
      node_id = response.parsed_body["node"]["id"]
      get disk_path("/nodes/#{node_id}/versions"), headers: owner_h
      versions = response.parsed_body["versions"]
      expect(versions.map { |v| v["number"] }).to eq([3, 2, 1])
      post disk_path("/versions/#{versions.last['id']}/restore"), headers: owner_h
      expect(response.parsed_body["version"]).to include("number" => 4, "size_bytes" => 1, "current" => true)
      expect(org.reload.disk_bytes_used).to eq(7)
    end

    it "refuses parts of unequal size before the last, as R2 would" do
      size = 20.megabytes
      upload = reserve(size)
      issue(upload, [1, 2, 3])
      storage.put_part(multipart_id(upload), 1, 8.megabytes)
      storage.put_part(multipart_id(upload), 2, 7.megabytes)
      storage.put_part(multipart_id(upload), 3, 5.megabytes)
      complete(upload)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"].first["message"]).to include("Part 2 is #{7.megabytes} bytes")
      expect(org.reload.disk_bytes_reserved).to eq(0)
    end

    it "refuses a part the API never issued, aborts and releases the reservation" do
      upload = reserve(10)
      issue(upload, [1])
      storage.put_part(multipart_id(upload), 1, 5)
      storage.put_part(multipart_id(upload), 2, 5)
      complete(upload)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"].first["message"]).to eq("Part 2 was not issued for this upload")
      expect(Disk::Upload.find_by!(key: upload["id"]).state).to eq("aborted")
      expect(org.reload.disk_bytes_reserved).to eq(0)
      expect(storage.multiparts).to be_empty
      expect(Disk::Node.where(key: upload["node_id"])).not_to exist
    end

    it "refuses parts that do not add up to the declared size" do
      upload = reserve(10)
      issue(upload, [1])
      storage.put_part(multipart_id(upload), 1, 9)
      complete(upload)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"].first["message"]).to include("add up to 9 bytes")
      expect(org.reload.disk_bytes_reserved).to eq(0)
    end

    it "aborts when the uploader lost edit access before completing" do
      join("edit")
      upload = reserve(10, headers: member_h)
      issue(upload, [1], headers: member_h)
      storage.put_part(multipart_id(upload), 1, 10)
      Disk::ShareMembership.where(membership: member).update_all(role: "view")
      complete(upload, headers: member_h)
      expect(response).to have_http_status(:forbidden)
      expect(org.reload.disk_bytes_reserved).to eq(0)
    end

    it "404s another org's upload" do
      upload = reserve(10)
      post "/api/v1/orgs/#{outsider_org.key}/disk/uploads/#{upload['id']}/complete", headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /uploads/:id" do
    it "lists what storage holds, to resume after a reload" do
      upload = reserve(20 * mib)
      issue(upload, [1, 2, 3])
      storage.put_part(multipart_id(upload), 1, 8 * mib)
      storage.put_part(multipart_id(upload), 2, 8 * mib)
      get disk_path("/uploads/#{upload['id']}"), headers: owner_h
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["upload"]["state"]).to eq("reserved")
      expect(response.parsed_body["parts"]).to eq([{ "number" => 1, "etag" => "\"etag1\"", "size_bytes" => 8 * mib },
                                                    { "number" => 2, "etag" => "\"etag2\"", "size_bytes" => 8 * mib }])
    end

    it "404s an unknown upload and another org's" do
      get disk_path("/uploads/dup_nope"), headers: owner_h
      expect(response).to have_http_status(:not_found)
      get "/api/v1/orgs/#{outsider_org.key}/disk/uploads/#{reserve(1)['id']}", headers: owner_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /uploads/:id" do
    it "cancels, releasing the reservation and the stored parts" do
      upload = reserve(20 * mib)
      delete disk_path("/uploads/#{upload['id']}"), headers: owner_h
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["upload"]["state"]).to eq("aborted")
      expect(org.reload.disk_bytes_reserved).to eq(0)
      expect(storage.multiparts).to be_empty
    end

    it "refuses a finished upload" do
      upload_file(1, name: "x.txt")
      delete disk_path("/uploads/#{Disk::Upload.last.key}"), headers: owner_h
      expect(response).to have_http_status(:conflict)
    end

    it "leaves a cancelled upload answering 409 upload_closed to parts and completion" do
      upload = reserve(20 * mib)
      delete disk_path("/uploads/#{upload['id']}"), headers: owner_h
      issue(upload, [1])
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to include("code" => "upload_closed")
      complete(upload)
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to include("code" => "upload_closed")
    end

    it "404s another org's upload" do
      delete "/api/v1/orgs/#{outsider_org.key}/disk/uploads/#{reserve(1)['id']}", headers: owner_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "sealed uploads" do
    let(:scope) { make_sealed_share.root_node }
    let(:sealed_folder) { make_sealed_node(scope) }
    let(:meta) { envelope }
    let(:wk) { b64(envelope) }
    let(:mf) { b64(envelope) }
    let(:sealed_body) do
      { parent_id: sealed_folder.key, name: nil, sealed: true, chunk_bytes: 4 * mib, key_epoch: 1,
        id: new_id("dnd"), metadata_ciphertext: b64(meta) }
    end

    def sealed_upload(**overrides)
      upload = reserve(32, **sealed_body, **overrides)
      issue(upload, [1])
      storage.put_part(multipart_id(upload), 1, 32)
      upload
    end

    it "stores the sealed fields and never a name" do
      upload = sealed_upload
      expect(upload["node_id"]).to eq(sealed_body[:id])
      complete(upload, wrapped_key: wk, manifest_ciphertext: mf)
      expect(response).to have_http_status(:ok)
      node = response.parsed_body["node"]
      expect(node).to include("id" => sealed_body[:id], "name" => nil, "mime" => nil, "sealed" => true,
                              "metadata_ciphertext" => b64(meta))
      expect(response.parsed_body["version"]).to include("chunk_bytes" => 4 * mib, "key_epoch" => 1, "size_bytes" => 32,
                                                         "wrapped_key" => wk, "manifest_ciphertext" => mf)
      expect(Disk::Event.last.detail).not_to have_key("name")
    end

    it "refuses with 409 and the current epoch when the key rotated before completion" do
      upload = sealed_upload
      Disk::ScopeEpoch.create!(organization: org, scope_node: scope, epoch: 2, previous_key_wrapped: envelope)
      key_grant!(scope, owner, epoch: 2)
      scope.update!(scope_epoch: 2)
      complete(upload, wrapped_key: wk, manifest_ciphertext: mf)
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to include("current_epoch" => 2, "code" => "epoch_changed")
      expect(org.reload.disk_bytes_reserved).to eq(0)
      expect(Disk::Upload.find_by!(key: upload["id"]).state).to eq("aborted")

      # The aborted upload goes on saying why, so the client starts afresh rather than resuming.
      issue(upload, [1])
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to include("code" => "epoch_changed", "current_epoch" => 2)
      complete(upload, wrapped_key: wk, manifest_ciphertext: mf)
      expect(response.parsed_body).to include("code" => "epoch_changed", "current_epoch" => 2)
    end

    it "answers upload_closed for a cancelled sealed upload whose key did not change" do
      upload = sealed_upload
      delete disk_path("/uploads/#{upload['id']}"), headers: owner_h
      issue(upload, [1])
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to include("code" => "upload_closed")
      expect(response.parsed_body).not_to have_key("current_epoch")
    end

    it "refuses a sealed completion without its wrapped key" do
      complete(sealed_upload)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
