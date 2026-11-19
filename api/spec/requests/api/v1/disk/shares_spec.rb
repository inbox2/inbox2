require "rails_helper"

RSpec.describe "Api::V1::Disk::Shares", type: :request do
  include_context "disk org"

  let(:owner_h) { auth_headers(owner_user) }
  let(:member_h) { auth_headers(member_user) }

  describe "GET /disk/shares" do
    it "lists the shares a member belongs to or that are open, not the others" do
      open = make_share("Open", openness: "org")
      mine = make_share("Mine")
      make_share("Hidden")
      Disk::ShareMembership.create!(organization: org, share: mine, membership: member, role: "view")
      Disk::ShareMembership.create!(organization: org, share: mine, membership: other, role: "edit")

      get disk_path("/shares"), headers: member_h
      expect(response).to have_http_status(:ok)
      rows = response.parsed_body["shares"]
      expect(rows.map { |s| s["name"] }).to eq(%w[Mine Open])
      expect(rows.find { |s| s["id"] == mine.key }["member_count"]).to eq(2)
      expect(rows.find { |s| s["id"] == open.key }["root_node_id"]).to eq(open.root_node.key)
    end

    it "shows the admin trash only to owners and admins" do
      gone = make_share("Gone", openness: "org", trashed_at: Time.current)
      get disk_path("/shares?trashed=true"), headers: owner_h
      expect(response.parsed_body["shares"].map { |s| s["id"] }).to eq([gone.key])
      get disk_path("/shares?trashed=true"), headers: member_h
      expect(response.parsed_body["shares"]).to eq([])
    end

    it "404s for another org" do
      get "/api/v1/orgs/#{outsider_org.key}/disk/shares", headers: member_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /disk/shares" do
    it "lets an owner create an open share that every member then sees" do
      post disk_path("/shares"), params: { name: "Launch", icon: "marketing", color: "#e06a3d", openness: "org",
                                           org_role: "edit" }, headers: owner_h, as: :json
      expect(response).to have_http_status(:created)
      share = response.parsed_body["share"]
      expect(share).to include("name" => "Launch", "icon" => "marketing", "openness" => "org", "org_role" => "edit")
      expect(share["id"]).to start_with("dsh_")

      get disk_path("/shares"), headers: member_h
      expect(response.parsed_body["shares"].map { |s| s["name"] }).to include("Launch")
    end

    it "refuses a plain member" do
      post disk_path("/shares"), params: { name: "Mine" }, headers: member_h, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "refuses a duplicate name, an unknown emblem and manage as the org role" do
      make_share("Sales")
      post disk_path("/shares"), params: { name: "sales" }, headers: owner_h, as: :json
      expect(response).to have_http_status(:conflict)
      post disk_path("/shares"), params: { name: "X", icon: "rocket" }, headers: owner_h, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      post disk_path("/shares"), params: { name: "Y", openness: "org", org_role: "manage" }, headers: owner_h, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "PATCH /disk/shares/:id" do
    let(:share) { make_share("Old") }

    it "lets a share manager rename, recolour and archive" do
      Disk::ShareMembership.create!(organization: org, share: share, membership: member, role: "manage")
      patch disk_path("/shares/#{share.key}"), params: { name: "New", icon: "sales", archived: true },
                                               headers: member_h, as: :json
      expect(response).to have_http_status(:ok)
      body = response.parsed_body["share"]
      expect(body).to include("name" => "New", "icon" => "sales")
      expect(body["archived_at"]).to be_present
    end

    it "refuses an editor" do
      Disk::ShareMembership.create!(organization: org, share: share, membership: member, role: "edit")
      patch disk_path("/shares/#{share.key}"), params: { name: "New" }, headers: member_h, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "404s a share the member is not in, and another org's share" do
      patch disk_path("/shares/#{share.key}"), params: { name: "New" }, headers: member_h, as: :json
      expect(response).to have_http_status(:not_found)
      patch disk_path("/shares/#{foreign_share.key}"), params: { name: "New" }, headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /disk/shares/:id, restore and purge" do
    let(:share) { make_share("Marketing", openness: "org") }

    it "needs the name typed back, then hides the share from members for 30 days" do
      delete disk_path("/shares/#{share.key}"), params: { confirm_name: "marketing" }, headers: owner_h, as: :json
      expect(response).to have_http_status(:unprocessable_content)

      delete disk_path("/shares/#{share.key}"), params: { confirm_name: "Marketing" }, headers: owner_h, as: :json
      expect(response).to have_http_status(:ok)
      expect(share.reload.purge_at).to be_within(1.minute).of(30.days.from_now)
      get disk_path("/nodes/#{share.root_node.key}"), headers: member_h
      expect(response).to have_http_status(:not_found)
      get disk_path("/nodes/#{share.root_node.key}"), headers: owner_h
      expect(response).to have_http_status(:ok)
    end

    it "refuses a member" do
      delete disk_path("/shares/#{share.key}"), params: { confirm_name: "Marketing" }, headers: member_h, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "restores, and refuses restoring a share that is not trashed" do
      post disk_path("/shares/#{share.key}/restore"), headers: owner_h
      expect(response).to have_http_status(:unprocessable_content)
      share.update!(trashed_at: Time.current, purge_at: 30.days.from_now)
      post disk_path("/shares/#{share.key}/restore"), headers: owner_h
      expect(response).to have_http_status(:ok)
      expect(share.reload.trashed_at).to be_nil
    end

    it "purges a trashed share with its contents and their bytes, and only a trashed one" do
      folder = make_folder(share.root_node, "Launch")
      file = make_stored_file(folder, "a.pdf", size: 9, versions: [2])
      keys = file.versions.pluck(:storage_key)
      delete disk_path("/shares/#{share.key}/purge"), headers: owner_h
      expect(response).to have_http_status(:unprocessable_content)
      share.update!(trashed_at: Time.current)
      get disk_path("/"), headers: owner_h
      expect(response.parsed_body["quota"]).to include("used_bytes" => 11, "trash_bytes" => 11)
      delete disk_path("/shares/#{share.key}/purge"), headers: owner_h
      expect(response).to have_http_status(:no_content)
      expect(Disk::Share.exists?(share.id)).to be(false)
      expect(Disk::Node.exists?(folder.id)).to be(false)
      expect(org.reload.disk_bytes_used).to eq(0)
      expect(storage.objects.keys & keys).to be_empty
    end

    it "404s another org's share on delete, restore and purge" do
      delete disk_path("/shares/#{foreign_share.key}"), params: { confirm_name: "Theirs" }, headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)
      post disk_path("/shares/#{foreign_share.key}/restore"), headers: owner_h
      expect(response).to have_http_status(:not_found)
      delete disk_path("/shares/#{foreign_share.key}/purge"), headers: owner_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /disk/shares/templates" do
    it "creates exactly the ticked templates with their emblems" do
      post disk_path("/shares/templates"), params: { names: %w[Marketing Finance HR] }, headers: owner_h, as: :json
      expect(response).to have_http_status(:created)
      rows = response.parsed_body["shares"]
      expect(rows.map { |s| [s["name"], s["icon"]] }).to eq([%w[Marketing marketing], %w[Finance finance], %w[HR hr]])
      expect(org.disk_shares.count).to eq(3)
    end

    it "skips a template that already exists" do
      make_share("Sales")
      post disk_path("/shares/templates"), params: { names: %w[Sales Design] }, headers: owner_h, as: :json
      expect(response.parsed_body["shares"].map { |s| s["name"] }).to eq(["Design"])
    end

    it "refuses unknown templates and plain members" do
      post disk_path("/shares/templates"), params: { names: %w[Legal] }, headers: owner_h, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      post disk_path("/shares/templates"), params: { names: %w[Sales] }, headers: member_h, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "404s for another org" do
      post "/api/v1/orgs/#{outsider_org.key}/disk/shares/templates", params: { names: %w[Sales] }, headers: owner_h,
                                                                       as: :json
      expect(response).to have_http_status(:not_found)
    end
  end
end
