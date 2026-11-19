require "rails_helper"

# Defects found by the 2026-10-03 review of the Disk API.
RSpec.describe "Disk review fixes", type: :request do
  include_context "disk org"

  let(:owner_h) { auth_headers(owner_user) }
  let(:share) { make_share("Marketing") }
  let(:root) { share.root_node }

  describe "completion and cancel are serialised on the upload row" do
    let(:ops) { Disk::UploadOps.new(owner) }

    def reserved_upload(size = 10)
      upload, = ops.reserve(size: size, parent_key: root.key, name: "a.pdf")
      ops.issue_parts(upload, [1])
      storage.put_part(upload.multipart_upload_id, 1, size)
      upload
    end

    it "refuses a cancel that arrives while the upload is completing, and the completion settles once" do
      upload = reserved_upload
      stale = Disk::Upload.find(upload.id) # the cancel request loaded it while still reserved
      upload.update!(state: Disk::Upload::STATE_COMPLETING)
      expect { ops.abort(stale) }.to raise_error(Disk::Refused) { |e| expect(e.status).to eq(409) }

      node, = Disk::UploadOps.finish!(upload)
      expect(storage.size(node.current_version.storage_key)).to eq(10)
      expect(org.reload).to have_attributes(disk_bytes_reserved: 0, disk_bytes_used: 10)
    end

    it "does not commit an upload aborted while a finisher held a stale copy" do
      upload = reserved_upload
      upload.update!(state: Disk::Upload::STATE_COMPLETING)
      stale = Disk::Upload.find(upload.id)
      Disk::UploadOps.abort!(upload) # e.g. a failed completion on another worker
      expect { Disk::UploadOps.finish!(stale) }.to raise_error(Disk::Refused) { |e| expect(e.status).to eq(409) }
      expect(Disk::Version.count).to eq(0)
      expect(org.reload).to have_attributes(disk_bytes_reserved: 0, disk_bytes_used: 0)
    end

    it "finishes once when two finishers race, and the expiry job leaves a completing upload alone" do
      upload = reserved_upload
      upload.update!(state: Disk::Upload::STATE_COMPLETING, expires_at: 1.hour.ago)
      Disk::ExpireUploadsJob.perform_now
      stale = Disk::Upload.find(upload.id)
      Disk::UploadOps.finish!(upload)
      expect(Disk::UploadOps.finish!(stale).last).to eq(upload.reload.version)
      expect(Disk::Version.count).to eq(1)
      expect(org.reload).to have_attributes(disk_bytes_reserved: 0, disk_bytes_used: 10)
    end
  end

  describe "moving between drives or shares" do
    let(:other_share) { make_share("Sales") }
    let(:folder) { make_folder(root, "Docs") }
    let!(:file) { make_stored_file(folder, "a.pdf", size: 1) }

    before do
      ops = Disk::NodeOps.new(owner)
      @link, @token = ops.create_link(file)
      ops.grant(folder, member, "view")
      agent_m = create(:membership, organization: org, member_type: Membership::TYPE_AGENT)
      @agent = create(:agent, organization: org, membership: agent_m)
      Disk::AgentGrant.create!(organization: org, agent: @agent, node: file, role: "view", granted_by: owner)
    end

    it "revokes links, grants and agent grants in the moved subtree and says so" do
      post disk_path("/nodes/#{folder.key}/move"), params: { target_id: c_root(owner).key }, headers: owner_h, as: :json
      expect(response).to have_http_status(:ok)
      revoked = response.parsed_body["revoked"]
      expect(revoked["links"]).to eq([@link.key])
      expect(revoked["grants"]).to eq([{ "node_id" => folder.key, "member_id" => member.key }])
      expect(revoked["agent_grants"]).to eq([{ "node_id" => file.key, "agent_id" => @agent.key }])
      expect(@link.reload.revoked_at).to be_present
      expect(Disk::Grant.count + Disk::AgentGrant.count).to eq(0)
      get "/api/v1/disk/links/#{@token}"
      expect(response).to have_http_status(:not_found)
      get disk_path("/nodes/#{file.key}"), headers: auth_headers(member_user)
      expect(response).to have_http_status(:not_found)
      expect(Disk::Event.find_by!(node: folder, action: "moved").detail).to include("revoked_links" => 1, "revoked_grants" => 2)
    end

    it "keeps them on a move within the same share" do
      post disk_path("/nodes/#{folder.key}/move"), params: { target_id: make_folder(root, "Archive").key }, headers: owner_h, as: :json
      expect(response.parsed_body["revoked"]).to eq("links" => [], "grants" => [], "agent_grants" => [])
      expect(@link.reload.revoked_at).to be_nil
      expect(Disk::Grant.count).to eq(1)
    end

    it "revokes on a move to another share too" do
      post disk_path("/nodes/#{folder.key}/move"), params: { target_id: other_share.root_node.key }, headers: owner_h, as: :json
      expect(response.parsed_body["revoked"]["links"]).to eq([@link.key])
    end
  end

  describe "restore to a drive's top" do
    it "needs edit on the top of the share when the original folder is gone" do
      folder = make_folder(root, "Docs")
      file = make_folder(folder, "a.txt")
      Disk::Grant.create!(organization: org, node: file, membership: member, role: "edit")
      Disk::NodeOps.new(member).trash(file)
      Disk::NodeOps.new(owner).trash(folder)
      post disk_path("/nodes/#{file.key}/restore"), headers: auth_headers(member_user), as: :json
      expect(response).to have_http_status(:not_found)
      expect(file.reload).to be_trashed

      Disk::ShareMembership.create!(organization: org, share: share, membership: member, role: "view")
      post disk_path("/nodes/#{file.key}/restore"), headers: auth_headers(member_user), as: :json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["errors"].first["message"]).to include("in the trash")
    end
  end

  describe "listings are paged" do
    it "pages file versions and page history" do
      file = make_stored_file(root, "a.pdf", size: 1, versions: [1, 1])
      get disk_path("/nodes/#{file.key}/versions"), params: { limit: 2 }, headers: owner_h
      expect(response.parsed_body["versions"].pluck("number")).to eq([3, 2])
      get disk_path("/nodes/#{file.key}/versions"), params: { limit: 2, cursor: response.parsed_body["next_cursor"] },
                                                   headers: owner_h
      expect(response.parsed_body).to include("next_cursor" => nil)
      expect(response.parsed_body["versions"].pluck("number")).to eq([1])

      page = make_folder(root, "P").tap { |n| n.update!(kind: Disk::Node::KIND_PAGE) }
      3.times { |i| Disk::Page.for(page).versions.create!(organization: org, revision: i + 1, markdown: "v#{i}") }
      get disk_path("/pages/#{page.key}/versions"), params: { limit: 2 }, headers: owner_h
      expect(response.parsed_body["versions"].pluck("revision")).to eq([3, 2])
      expect(response.parsed_body["next_cursor"]).to eq("2")
    end
  end
end
