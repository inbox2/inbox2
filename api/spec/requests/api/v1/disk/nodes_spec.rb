require "rails_helper"

RSpec.describe "Api::V1::Disk::Nodes", type: :request do
  include_context "disk org"

  let(:owner_h) { auth_headers(owner_user) }
  let(:member_h) { auth_headers(member_user) }
  let(:share) { make_share("Marketing") }
  let(:root) { share.root_node }

  def join(role, who = member) = Disk::ShareMembership.create!(organization: org, share: share, membership: who, role: role)

  describe "GET /nodes/:id" do
    it "returns the node with its path and where access comes from, and records a file as recent" do
      join("edit")
      launch = make_folder(root, "Launch")
      file = make_file(launch, "brief.pdf", mime: "application/pdf")
      get disk_path("/nodes/#{file.key}"), headers: member_h
      expect(response).to have_http_status(:ok)
      node = response.parsed_body["node"]
      expect(node["path"].map { |s| s["name"] }).to eq(["Marketing", "Launch", "brief.pdf"])
      expect(node["access"]["role"]).to eq("edit")
      expect(node["access"]["sources"]).to eq([{ "kind" => "share_member", "role" => "edit", "node_id" => nil,
                                                 "share_id" => share.key }])
      expect(Disk::Recent.where(membership: member, node: file)).to exist
    end

    it "trims the path to what a grantee can see" do
      launch = make_folder(root, "Launch")
      assets = make_folder(launch, "Assets")
      Disk::Grant.create!(organization: org, node: launch, membership: member, role: "view")
      get disk_path("/nodes/#{assets.key}"), headers: member_h
      expect(response.parsed_body["node"]["path"].map { |s| s["name"] }).to eq(%w[Launch Assets])
    end

    it "404s a node the member cannot reach, and another org's node" do
      get disk_path("/nodes/#{make_folder(root, 'Secret').key}"), headers: member_h
      expect(response).to have_http_status(:not_found)
      get disk_path("/nodes/#{foreign_node.key}"), headers: owner_h
      expect(response).to have_http_status(:not_found)
    end

    it "keeps a colleague's C:\\ from owners" do
      get disk_path("/nodes/#{make_folder(c_root(member), 'Private').key}"), headers: owner_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /nodes/:id/children" do
    before do
      join("view")
      make_folder(root, "Zeta")
      make_folder(root, "Alpha")
      make_file(root, "big.mp4", mime: "video/mp4", size: 900, content_modified_at: 2.days.ago, by: other)
      make_file(root, "song.mp3", mime: "audio/mpeg", size: 50, content_modified_at: 20.days.ago)
      make_file(root, "deck.pptx", size: 10,
                                   mime: "application/vnd.openxmlformats-officedocument.presentationml.presentation")
      make_file(root, "data.csv", mime: "text/csv", size: 5)
      make_file(root, "notes.md", mime: "text/markdown", size: 7)
      make_file(root, "old.txt", mime: "text/plain").update!(trashed_at: Time.current, trash_root: true)
    end

    def names(query = "")
      get disk_path("/nodes/#{root.key}/children#{query}"), headers: member_h
      expect(response).to have_http_status(:ok)
      response.parsed_body["nodes"].map { |n| n["name"] }
    end

    it "sorts by name with folders first and leaves trashed items out" do
      expect(names).to eq(%w[Alpha Zeta big.mp4 data.csv deck.pptx notes.md song.mp3])
    end

    it "sorts by size, largest first, folders still on top" do
      expect(names("?sort=size&dir=desc")).to eq(%w[Alpha Zeta big.mp4 song.mp3 deck.pptx notes.md data.csv])
    end

    it "filters by type family and modified date, with a count against the total" do
      expect(names("?type=media&modified=7d")).to eq(%w[big.mp4])
      expect(response.parsed_body).to include("count" => 1, "total" => 7)
      expect(names("?type=documents")).to eq(%w[notes.md])
      expect(names("?type=sheets,slides")).to eq(%w[data.csv deck.pptx])
      expect(names("?type=folders")).to eq(%w[Alpha Zeta])
      expect(names("?by=#{other.key}")).to eq(%w[big.mp4])
      expect(names("?type=pages")).to eq([])
      expect(response.parsed_body).to include("count" => 0, "total" => 7)
    end

    it "pages with a cursor" do
      get disk_path("/nodes/#{root.key}/children?limit=4"), headers: member_h
      first = response.parsed_body
      expect(first["nodes"].size).to eq(4)
      get disk_path("/nodes/#{root.key}/children?limit=4&cursor=#{first['next_cursor']}"), headers: member_h
      expect(response.parsed_body["nodes"].size).to eq(3)
      expect(response.parsed_body["next_cursor"]).to be_nil
    end

    it "refuses an unknown type and a file as a folder" do
      get disk_path("/nodes/#{root.key}/children?type=spreadsheets"), headers: member_h
      expect(response).to have_http_status(:unprocessable_content)
      get disk_path("/nodes/#{Disk::Node.find_by(name: 'big.mp4').key}/children"), headers: member_h
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "404s another org's folder" do
      get disk_path("/nodes/#{foreign_share.root_node.key}/children"), headers: owner_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /nodes" do
    it "creates a folder in C:\\ and in a share I can edit" do
      join("edit")
      post disk_path("/nodes"), params: { parent_id: c_root(member).key, name: "Mine" }, headers: member_h, as: :json
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["node"]).to include("name" => "Mine", "drive" => "C", "kind" => "folder")
      post disk_path("/nodes"), params: { parent_id: root.key, name: "Ours", kind: "folder" }, headers: member_h, as: :json
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["node"]["modified_by"]["name"]).to eq("Mo Member")
    end

    it "asks on a name clash, and keeps both when told to" do
      join("edit")
      make_folder(root, "Launch")
      post disk_path("/nodes"), params: { parent_id: root.key, name: "launch" }, headers: member_h, as: :json
      expect(response).to have_http_status(:conflict)
      post disk_path("/nodes"), params: { parent_id: root.key, name: "Launch", on_conflict: "keep_both" },
                                headers: member_h, as: :json
      expect(response.parsed_body["node"]["name"]).to eq("Launch (1)")
    end

    it "refuses a viewer, a kind other than folder or page, and a bad name" do
      join("view")
      post disk_path("/nodes"), params: { parent_id: root.key, name: "X" }, headers: member_h, as: :json
      expect(response).to have_http_status(:forbidden)
      post disk_path("/nodes"), params: { parent_id: c_root(member).key, name: "X", kind: "file" }, headers: member_h,
                                as: :json
      expect(response).to have_http_status(:unprocessable_content)
      post disk_path("/nodes"), params: { parent_id: c_root(member).key, name: "a/b" }, headers: member_h, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "404s a parent in another org" do
      post disk_path("/nodes"), params: { parent_id: foreign_share.root_node.key, name: "X" }, headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /nodes/:id" do
    let(:folder) { make_folder(root, "Draft") }

    it "renames with an editor and stars with a viewer" do
      join("edit")
      patch disk_path("/nodes/#{folder.key}"), params: { name: "Final" }, headers: member_h, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["node"]).to include("name" => "Final")
      expect(Disk::Event.find_by(node: folder, action: "renamed").detail).to eq("from" => "Draft", "to" => "Final")

      Disk::ShareMembership.find_by(membership: member).update!(role: "view")
      patch disk_path("/nodes/#{folder.key}"), params: { starred: true }, headers: member_h, as: :json
      expect(response.parsed_body["node"]["starred"]).to be(true)
      get disk_path("/views/starred"), headers: member_h
      expect(response.parsed_body["nodes"].map { |n| n["id"] }).to eq([folder.key])
    end

    it "refuses a viewer renaming, a clash, and renaming a drive's top folder" do
      join("view")
      patch disk_path("/nodes/#{folder.key}"), params: { name: "Final" }, headers: member_h, as: :json
      expect(response).to have_http_status(:forbidden)
      make_folder(root, "Taken")
      patch disk_path("/nodes/#{folder.key}"), params: { name: "taken" }, headers: owner_h, as: :json
      expect(response).to have_http_status(:conflict)
      patch disk_path("/nodes/#{root.key}"), params: { name: "x" }, headers: owner_h, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "404s another org's node" do
      patch disk_path("/nodes/#{foreign_node.key}"), params: { starred: true }, headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /nodes/:id/move" do
    it "moves a folder from C:\\ into a share, contents and all, and it takes the share's access" do
      join("edit")
      mine = make_folder(c_root(member), "Campaign")
      inner = make_folder(mine, "Shots")
      post disk_path("/nodes/#{mine.key}/move"), params: { target_id: root.key }, headers: member_h, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["node"]["drive"]).to eq("D")
      expect(inner.reload).to have_attributes(share_id: share.id, custodian_membership_id: nil)
      join("view", other)
      get disk_path("/nodes/#{inner.key}"), headers: auth_headers(other_user)
      expect(response.parsed_body["node"]["access"]["role"]).to eq("view")
    end

    it "refuses a move into its own descendant, and a viewer" do
      a = make_folder(root, "A")
      b = make_folder(a, "B")
      post disk_path("/nodes/#{a.key}/move"), params: { target_id: b.key }, headers: owner_h, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      join("view")
      post disk_path("/nodes/#{b.key}/move"), params: { target_id: root.key }, headers: member_h, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "404s a target in another org" do
      a = make_folder(root, "A")
      post disk_path("/nodes/#{a.key}/move"), params: { target_id: foreign_node.key }, headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /nodes/:id/copy" do
    it "deep-copies a folder tree, keeping both on a clash" do
      a = make_folder(root, "A")
      make_folder(make_folder(a, "B"), "C")
      post disk_path("/nodes/#{a.key}/copy"), params: { target_id: root.key, on_conflict: "keep_both" },
                                              headers: owner_h, as: :json
      expect(response).to have_http_status(:created)
      copy = Disk::Node.find_by!(key: response.parsed_body["node"]["id"])
      expect(copy.name).to eq("A (1)")
      expect(copy.children.first.children.first.name).to eq("C")
    end

    it "copies files across drives with their current version only, counted in the quota" do
      a = make_folder(root, "A")
      x = make_stored_file(a, "x.pdf", size: 7, versions: [3])
      expect do
        post disk_path("/nodes/#{a.key}/copy"), params: { target_id: c_root(owner).key }, headers: owner_h, as: :json
      end.to change { owner_user.personal_organization.reload.disk_bytes_used }.by(7) # the C:\ is the person's own
      expect(response).to have_http_status(:created)
      copy = Disk::Node.find_by!(key: response.parsed_body["node"]["id"])
      x_copy = copy.children.first
      expect(x_copy).to have_attributes(name: "x.pdf", mime: "application/pdf", size_bytes: 7)
      expect(x_copy.versions.pluck(:number, :size_bytes)).to eq([[1, 7]])
      expect(x_copy.current_version.storage_key).not_to eq(x.current_version.storage_key)
      expect(storage.size(x_copy.current_version.storage_key)).to eq(7)
      expect([copy.size_bytes, c_root(owner).reload.size_bytes]).to eq([7, 7])
    end

    it "refuses a copy over quota and deletes the copied objects" do
      make_stored_file(root, "big.pdf", size: 7)
      owner_user.personal_organization.update!(disk_quota_override_gb: 1, disk_bytes_used: 1.gigabyte - 3)
      post disk_path("/nodes/#{root.children.first.key}/copy"), params: { target_id: c_root(owner).key },
                                                                headers: owner_h, as: :json
      expect(response.parsed_body["code"]).to eq("disk_quota_exceeded")
      expect(storage.objects.size).to eq(1)
    end

    it "refuses a viewer target" do
      join("view")
      post disk_path("/nodes/#{make_folder(root, 'E').key}/copy"), params: { target_id: root.key }, headers: member_h,
                                                                  as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "404s a source in another org" do
      post disk_path("/nodes/#{foreign_node.key}/copy"), params: { target_id: root.key }, headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "trash lifecycle" do
    let(:folder) { make_folder(root, "Launch") }
    let!(:inner) { make_folder(folder, "Assets") }

    it "trashes a folder with its contents and restores it to its place" do
      delete disk_path("/nodes/#{folder.key}"), headers: owner_h
      expect(response).to have_http_status(:ok)
      expect(inner.reload.trashed_at).to be_present
      get disk_path("/views/trash"), headers: owner_h
      expect(response.parsed_body["nodes"].map { |n| n["id"] }).to eq([folder.key])

      post disk_path("/nodes/#{folder.key}/restore"), headers: owner_h
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("restored_to_root" => false)
      expect(folder.reload).to have_attributes(trashed_at: nil, parent_id: root.id)
      expect(inner.reload.trashed_at).to be_nil
    end

    it "leaves a child deleted on its own in the trash when its parent comes back" do
      delete disk_path("/nodes/#{inner.key}"), headers: owner_h
      delete disk_path("/nodes/#{folder.key}"), headers: owner_h
      post disk_path("/nodes/#{folder.key}/restore"), headers: owner_h
      expect(inner.reload.trashed_at).to be_present
    end

    it "restores to the top of the drive when its folder is in the trash, keeping both names" do
      delete disk_path("/nodes/#{inner.key}"), headers: owner_h
      delete disk_path("/nodes/#{folder.key}"), headers: owner_h
      make_folder(root, "Assets")
      post disk_path("/nodes/#{inner.key}/restore"), headers: owner_h
      expect(response.parsed_body).to include("restored_to_root" => true)
      expect(inner.reload).to have_attributes(parent_id: root.id, name: "Assets (1)")
    end

    it "purges only from the trash" do
      delete disk_path("/nodes/#{folder.key}/purge"), headers: owner_h
      expect(response).to have_http_status(:unprocessable_content)
      delete disk_path("/nodes/#{folder.key}"), headers: owner_h
      delete disk_path("/nodes/#{folder.key}/purge"), headers: owner_h
      expect(response).to have_http_status(:no_content)
      expect(Disk::Node.where(id: [folder.id, inner.id])).to be_empty
      expect(Disk::Event.where(action: "purged").last.detail).to eq("name" => "Launch")
    end

    it "purges with empty_only only when nothing is beneath, so a seal's late arrival survives" do
      delete disk_path("/nodes/#{folder.key}"), headers: owner_h
      delete disk_path("/nodes/#{folder.key}/purge?empty_only=1"), headers: owner_h
      expect(response).to have_http_status(:conflict)
      expect(Disk::Node.where(id: [folder.id, inner.id]).count).to eq(2)

      empty = make_folder(root, "Empty")
      delete disk_path("/nodes/#{empty.key}"), headers: owner_h
      delete disk_path("/nodes/#{empty.key}/purge?empty_only=1"), headers: owner_h
      expect(response).to have_http_status(:no_content)
    end

    it "keeps folder sizes right through trash, restore, move and purge, and purge frees the quota" do
      make_stored_file(inner, "a.pdf", size: 10, versions: [4])
      expect([inner.reload.size_bytes, folder.reload.size_bytes, root.reload.size_bytes]).to eq([10, 10, 10])
      delete disk_path("/nodes/#{inner.key}"), headers: owner_h
      expect([folder.reload.size_bytes, root.reload.size_bytes]).to eq([0, 0])
      post disk_path("/nodes/#{inner.key}/restore"), headers: owner_h
      expect([folder.reload.size_bytes, root.reload.size_bytes]).to eq([10, 10])
      other_folder = make_folder(root, "Other")
      post disk_path("/nodes/#{inner.key}/move"), params: { target_id: other_folder.key }, headers: owner_h, as: :json
      expect([folder.reload.size_bytes, other_folder.reload.size_bytes, root.reload.size_bytes]).to eq([0, 10, 10])

      get disk_path("/"), headers: owner_h
      expect(response.parsed_body["quota"]).to include("used_bytes" => 14, "files_bytes" => 10, "versions_bytes" => 4)
      expect(response.parsed_body["quota"]["types_bytes"].values.sum).to eq(10)
      delete disk_path("/nodes/#{inner.key}"), headers: owner_h
      get disk_path("/"), headers: owner_h
      expect(response.parsed_body["quota"]).to include("used_bytes" => 14, "trash_bytes" => 14)

      keys = Disk::Version.pluck(:storage_key)
      delete disk_path("/nodes/#{inner.key}/purge"), headers: owner_h
      expect(response).to have_http_status(:no_content)
      expect(org.reload.disk_bytes_used).to eq(0)
      expect(Disk::Version.count).to eq(0)
      expect(storage.deleted).to include(*keys)
      expect(root.reload.size_bytes).to eq(0)
    end

    it "refuses a viewer and the drive's top folder" do
      join("view")
      delete disk_path("/nodes/#{folder.key}"), headers: member_h
      expect(response).to have_http_status(:forbidden)
      delete disk_path("/nodes/#{root.key}"), headers: owner_h
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "404s another org's node on trash, restore and purge" do
      delete disk_path("/nodes/#{foreign_node.key}"), headers: owner_h
      expect(response).to have_http_status(:not_found)
      post disk_path("/nodes/#{foreign_node.key}/restore"), headers: owner_h
      expect(response).to have_http_status(:not_found)
      delete disk_path("/nodes/#{foreign_node.key}/purge"), headers: owner_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /nodes/bulk" do
    it "trashes several at once and reports the ones refused" do
      join("edit")
      mine = Array.new(2) { |i| make_folder(root, "F#{i}") }
      not_mine = make_folder(c_root(other), "Private")
      post disk_path("/nodes/bulk"), params: { op: "trash", ids: mine.map(&:key) + [not_mine.key, foreign_node.key] },
                                     headers: member_h, as: :json
      expect(response).to have_http_status(:ok)
      results = response.parsed_body["results"]
      expect(results.map { |r| r["ok"] }).to eq([true, true, false, false])
      expect(results.last["error"]).to eq("Not found")
      expect(mine.map { |n| n.reload.trashed? }).to all(be(true))
    end

    it "moves several, refusing per item" do
      join("edit")
      target = make_folder(root, "Target")
      a = make_folder(root, "A")
      post disk_path("/nodes/bulk"), params: { op: "move", ids: [a.key, target.key], target_id: target.key },
                                     headers: member_h, as: :json
      expect(response.parsed_body["results"].map { |r| r["ok"] }).to eq([true, false])
      expect(a.reload.parent_id).to eq(target.id)
    end

    it "refuses an unknown op" do
      post disk_path("/nodes/bulk"), params: { op: "purge", ids: ["x"] }, headers: owner_h, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET /nodes/:id/events" do
    it "shows a node's history, and a share's on its top folder" do
      join("edit")
      post disk_path("/nodes"), params: { parent_id: root.key, name: "Launch" }, headers: member_h, as: :json
      id = response.parsed_body["node"]["id"]
      patch disk_path("/nodes/#{id}"), params: { name: "Launch 2026" }, headers: member_h, as: :json

      get disk_path("/nodes/#{id}/events"), headers: member_h
      expect(response).to have_http_status(:ok)
      events = response.parsed_body["events"]
      expect(events.map { |e| e["action"] }).to eq(%w[renamed created])
      expect(events.first["actor"]["name"]).to eq("Mo Member")

      get disk_path("/nodes/#{root.key}/events"), headers: member_h
      expect(response.parsed_body["events"].size).to eq(2)
    end

    it "404s a node the caller cannot see and another org's node" do
      get disk_path("/nodes/#{root.key}/events"), headers: member_h
      expect(response).to have_http_status(:not_found)
      get disk_path("/nodes/#{foreign_node.key}/events"), headers: owner_h
      expect(response).to have_http_status(:not_found)
    end
  end
end
