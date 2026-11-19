require "rails_helper"

# Spec F2 (download, version history, restore), Non-functional (access on every
# byte path, version ids 404 across tenants, attachment disposition).
RSpec.describe "Api::V1::Disk::Versions and downloads", type: :request do
  include_context "disk org"

  let(:owner_h) { auth_headers(owner_user) }
  let(:member_h) { auth_headers(member_user) }
  let(:share) { make_share("Marketing") }
  let(:root) { share.root_node }
  let(:file) { make_stored_file(root, "page.html", size: 30, versions: [10, 20], mime: "text/html") }

  def join(role, who = member) = Disk::ShareMembership.create!(organization: org, share: share, membership: who, role: role)
  def foreign_version = make_stored_file(foreign_share.root_node, "theirs.pdf", size: 1).current_version

  describe "GET /nodes/:id/download" do
    it "issues a short-lived URL for the current version that downloads as an attachment" do
      join("view")
      get disk_path("/nodes/#{file.key}/download"), headers: member_h
      expect(response).to have_http_status(:ok)
      download = response.parsed_body["download"]
      expect(download["url"]).to include(file.current_version.storage_key, "attachment=page.html")
      expect(download).to include("version_id" => file.current_version.key, "size_bytes" => 30, "variant" => nil)
      expect(Time.zone.parse(download["expires_at"])).to be_within(1.minute).of(5.minutes.from_now)
    end

    it "refuses a folder, and a member whose access was removed gets no new URL" do
      get disk_path("/nodes/#{root.key}/download"), headers: owner_h
      expect(response).to have_http_status(:unprocessable_content)
      join("view")
      Disk::ShareMembership.where(membership: member).delete_all
      get disk_path("/nodes/#{file.key}/download"), headers: member_h
      expect(response).to have_http_status(:not_found)
    end

    it "gives a grantee whose grant was removed no new URL" do
      grant = Disk::Grant.create!(organization: org, node: file, membership: member, role: "view")
      get disk_path("/nodes/#{file.key}/download"), headers: member_h
      expect(response).to have_http_status(:ok)
      grant.destroy!
      get disk_path("/nodes/#{file.key}/download"), headers: member_h
      expect(response).to have_http_status(:not_found)
      get disk_path("/versions/#{file.current_version.key}/download"), headers: member_h
      expect(response).to have_http_status(:not_found)
    end

    it "404s another org's file" do
      get disk_path("/nodes/#{foreign_version.node.key}/download"), headers: owner_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /nodes/:id/versions" do
    it "lists the history newest first with the current one marked" do
      get disk_path("/nodes/#{file.key}/versions"), headers: owner_h
      expect(response).to have_http_status(:ok)
      versions = response.parsed_body["versions"]
      expect(versions.map { |v| [v["number"], v["size_bytes"], v["current"]] }).to eq([[3, 30, true], [2, 20, false],
                                                                                         [1, 10, false]])
      expect(versions.last["expires_at"]).to be_present
    end

    it "404s a node the member cannot see and another org's" do
      get disk_path("/nodes/#{file.key}/versions"), headers: member_h
      expect(response).to have_http_status(:not_found)
      get disk_path("/nodes/#{foreign_version.node.key}/versions"), headers: owner_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /versions/:id/download" do
    it "downloads an older version, and its rendition once it has landed" do
      old = file.versions.find_by!(number: 1)
      get disk_path("/versions/#{old.key}/download"), headers: owner_h
      expect(response.parsed_body["download"]).to include("version_id" => old.key, "size_bytes" => 10)
      get disk_path("/versions/#{old.key}/download?variant=rendition"), headers: owner_h
      expect(response).to have_http_status(:not_found)
      put disk_path("/versions/#{old.key}/rendition"), headers: owner_h
      get disk_path("/versions/#{old.key}/download?variant=rendition"), headers: owner_h
      expect(response).to have_http_status(:not_found) # presigned, not uploaded yet
      storage.put("#{old.storage_key}.rendition", 5)
      put disk_path("/versions/#{old.key}/rendition"), params: { landed: true }, headers: owner_h
      expect(response.parsed_body["version"]).to include("has_rendition" => true)
      get disk_path("/versions/#{old.key}/download?variant=rendition"), headers: owner_h
      expect(response.parsed_body["download"]["url"]).to include("#{old.storage_key}.rendition", "attachment=page.pdf")
    end

    it "refuses an unknown variant" do
      get disk_path("/versions/#{file.current_version.key}/download?variant=raw"), headers: owner_h
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "404s another org's version" do
      get disk_path("/versions/#{foreign_version.key}/download"), headers: owner_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /versions/:id/restore" do
    it "makes the restored version the newest, copied in storage, counted in the quota" do
      first = file.versions.find_by!(number: 1)
      expect do
        post disk_path("/versions/#{first.key}/restore"), headers: owner_h
      end.to change { org.reload.disk_bytes_used }.by(10)
      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["version"]).to include("number" => 4, "size_bytes" => 10, "current" => true)
      expect(body["node"]["size_bytes"]).to eq(10)
      restored = Disk::Version.find_by!(key: body["version"]["id"])
      expect(restored.storage_key).not_to eq(first.storage_key)
      expect(storage.size(restored.storage_key)).to eq(10)
      expect(root.reload.size_bytes).to eq(10)
      expect(Disk::Event.last).to have_attributes(action: "version_restored")
    end

    it "refuses a viewer and the current version" do
      join("view")
      post disk_path("/versions/#{file.versions.find_by!(number: 1).key}/restore"), headers: member_h
      expect(response).to have_http_status(:forbidden)
      post disk_path("/versions/#{file.current_version.key}/restore"), headers: owner_h
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "404s another org's version" do
      post disk_path("/versions/#{foreign_version.key}/restore"), headers: owner_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PUT /versions/:id/thumbnail" do
    it "presigns a PUT beside the version's object and leaves the quota alone" do
      version = file.current_version
      expect do
        put disk_path("/versions/#{version.key}/thumbnail"), headers: owner_h
      end.not_to(change { org.reload.disk_bytes_used })
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["upload"]["url"]).to include("#{version.storage_key}.thumbnail")
      expect(version.reload.thumbnail_storage_key).to be_nil
    end

    it "records the object only once it is in storage" do
      version = file.current_version
      put disk_path("/versions/#{version.key}/thumbnail"), params: { landed: true }, headers: owner_h
      expect(response).to have_http_status(:unprocessable_content)
      expect(version.reload.thumbnail_storage_key).to be_nil

      storage.put("#{version.storage_key}.thumbnail", 9)
      expect do
        put disk_path("/versions/#{version.key}/thumbnail"), params: { landed: true }, headers: owner_h
      end.not_to(change { org.reload.disk_bytes_used })
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["version"]).to include("has_thumbnail" => true)
      expect(version.reload.thumbnail_storage_key).to eq("#{version.storage_key}.thumbnail")
    end

    it "refuses a viewer who says an object landed" do
      join("view")
      storage.put("#{file.current_version.storage_key}.thumbnail", 9)
      put disk_path("/versions/#{file.current_version.key}/thumbnail"), params: { landed: true }, headers: member_h
      expect(response).to have_http_status(:forbidden)
      expect(file.current_version.reload.thumbnail_storage_key).to be_nil
    end

    it "refuses a viewer" do
      join("view")
      put disk_path("/versions/#{file.current_version.key}/thumbnail"), headers: member_h
      expect(response).to have_http_status(:forbidden)
    end

    it "404s another org's version" do
      put disk_path("/versions/#{foreign_version.key}/rendition"), headers: owner_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /nodes/:id/tree" do
    it "lists every live item beneath a folder, flat and paged, with each file's current version" do
      a = make_folder(root, "A")
      make_stored_file(a, "x.pdf", size: 3)
      make_folder(make_folder(a, "B"), "C")
      make_folder(a, "Gone").update!(trashed_at: Time.current, trash_root: true)
      get disk_path("/nodes/#{a.key}/tree?limit=2"), headers: owner_h
      expect(response).to have_http_status(:ok)
      first = response.parsed_body
      expect(first["nodes"].size).to eq(2)
      get disk_path("/nodes/#{a.key}/tree?cursor=#{first['next_cursor']}"), headers: owner_h
      nodes = first["nodes"] + response.parsed_body["nodes"]
      expect(nodes.map { |n| n["name"] }).to contain_exactly("x.pdf", "B", "C")
      x = nodes.find { |n| n["name"] == "x.pdf" }
      expect(x).to include("parent_id" => a.key, "size_bytes" => 3)
      expect(x["current_version_id"]).to start_with("dvr_")
    end

    it "refuses a file and 404s another org's folder" do
      get disk_path("/nodes/#{file.key}/tree"), headers: owner_h
      expect(response).to have_http_status(:unprocessable_content)
      get disk_path("/nodes/#{foreign_node.key}/tree"), headers: owner_h
      expect(response).to have_http_status(:not_found)
    end
  end
end
