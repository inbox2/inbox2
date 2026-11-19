require "rails_helper"

# The console's Disk page, offboarding and the org export (spec F11).
RSpec.describe "Disk admin", type: :request do
  include_context "disk org"

  let(:owner_h) { auth_headers(owner_user) }
  let(:member_h) { auth_headers(member_user) }
  let(:admin) { create(:membership, user: create(:user, display_name: "Ada Admin"), organization: org, role: "admin") }
  let(:admin_h) { auth_headers(admin.user) }
  let(:share) { make_share("Marketing", openness: Disk::Share::OPENNESS_ORG, org_role: Disk::ROLE_EDIT) }

  def admin_path(p) = disk_path("/admin#{p}")

  describe "role checks" do
    it "lets owners and admins in and keeps members out of every console endpoint" do
      [[:get, "/usage"], [:get, "/links"], [:get, "/events"], [:get, "/export"],
       [:put, "/settings"], [:delete, "/links/dln_x"]].each do |verb, p|
        send(verb, admin_path(p), headers: member_h, as: :json)
        expect(response).to have_http_status(:forbidden), "#{verb} #{p}"
      end
      get admin_path("/usage"), headers: admin_h
      expect(response).to have_http_status(:ok)
    end

    it "is not found for another org's member" do
      get "/api/v1/orgs/#{outsider_org.key}/disk/admin/usage", headers: owner_h
      expect(response).to have_http_status(:not_found)
      stranger = create(:membership, organization: outsider_org)
      get admin_path("/offboarding/#{stranger.key}"), headers: owner_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /admin/usage" do
    it "splits the meter per share, matching the org total; a member's C:\\ is their own and not in it" do
      make_stored_file(share.root_node, "a.pdf", size: 10, versions: [5])
      make_stored_file(c_root(member), "b.pdf", size: 7)
      get admin_path("/usage"), headers: owner_h
      usage = response.parsed_body["usage"]
      expect(usage["shares"].find { |r| r["share"]["id"] == share.key }["bytes"]).to eq(15)
      expect(usage["quota"]["used_bytes"]).to eq(15)
      expect(usage["shares"].sum { |r| r["bytes"] }).to eq(15)
      expect(member_user.personal_organization.reload.disk_bytes_used).to eq(7)
      expect(usage["settings"]).to include("links_enabled" => true, "state" => "active")
    end
  end

  describe "links" do
    it "lists every live link in the org's shares (a C:\\ link is the person's own), and revokes one at once" do
      file = make_stored_file(share.root_node, "mine.pdf", size: 1)
      link, token = Disk::NodeOps.new(owner).create_link(file)
      personal_link, = Disk::NodeOps.new(member).create_link(make_stored_file(c_root(member), "own.pdf", size: 1))
      get admin_path("/links"), headers: admin_h
      row = response.parsed_body["links"].first
      expect(row).to include("id" => link.key)
      expect(row["node"]).to include("id" => file.key, "name" => "mine.pdf")
      expect(row["token"]).to be_nil
      expect(response.parsed_body["links"].pluck("id")).not_to include(personal_link.key)

      delete admin_path("/links/#{link.key}"), headers: admin_h
      expect(response).to have_http_status(:no_content)
      get "/api/v1/disk/links/#{token}"
      expect(response).to have_http_status(:not_found)
      delete admin_path("/links/#{Disk::NodeOps.new(owner).create_link(make_folder(share.root_node, 'x')).first.key.sub('dln_', 'dln_zz')}"),
             headers: admin_h
      expect(response).to have_http_status(:not_found)
    end

    it "turns links off for the org" do
      put admin_path("/settings"), params: { links_enabled: false }, headers: owner_h, as: :json
      expect(response.parsed_body["settings"]).to include("links_enabled" => false)
      expect(org.reload.disk_links_enabled).to be(false)
      put admin_path("/settings"), headers: owner_h, as: :json
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "removing a member" do
    it "leaves their C:\\ with them: it is their own, in no org's quota (decided 2026-10-07)" do
      mine = make_stored_file(make_folder(c_root(member), "Clients"), "deal.pdf", size: 9)
      personal = member_user.personal_organization
      expect(personal.reload.disk_bytes_used).to eq(9)
      expect(org.reload.disk_bytes_used).to eq(0)

      delete "/api/v1/orgs/#{org.key}/members/#{member.key}", headers: owner_h
      expect(response).to have_http_status(:no_content)
      expect(mine.reload.custodian_membership_id).to eq(member_user.personal_membership.id)
      expect(personal.reload.disk_bytes_used).to eq(9)
    end
  end

  describe "GET /admin/events" do
    let(:sales) { make_share("Sales") }
    let!(:brief) { Disk::NodeOps.new(owner).create_folder(parent_key: share.root_node.key, name: "Brief") }

    before do
      Disk::NodeOps.new(owner).create_folder(parent_key: sales.root_node.key, name: "Leads")
      bot = create(:membership, organization: org, role: "member", member_type: Membership::TYPE_AGENT)
      create(:agent, organization: org, membership: bot, name: "Filer")
      Disk::Event.record!(Disk::Event::ACTION_RENAMED, actor: bot, node: brief, from: "a", to: "Brief")
      vault = make_sealed_share("Vault")
      Disk::Event.record!(Disk::Event::ACTION_CREATED, actor: owner, node: make_sealed_node(vault.root_node), sealed: true)
      Disk::Event.record!(Disk::Event::ACTION_PREVIEW_FAILED, actor: owner, node: brief, renderer: "pdf")
      Disk::Event.where(node_id: brief.id, action: Disk::Event::ACTION_CREATED).update_all(created_at: 3.days.ago)
    end

    def events(**query)
      get admin_path("/events"), params: query, headers: admin_h
      expect(response).to have_http_status(:ok)
      response.parsed_body["events"]
    end

    it "lists every share's events newest first, names agents, hides sealed names and leaves out preview failures" do
      rows = events
      expect(rows.pluck("action")).not_to include("preview_failed")
      expect(rows.first["item"]).to eq("kind" => "folder", "sealed" => true, "name" => nil)
      agent_row = rows.find { |r| r["action"] == "renamed" }
      expect(agent_row["actor"]).to include("agent" => true, "name" => a_string_including("Filer"))
      expect(agent_row["agent_id"]).to be_present
      expect(agent_row).to include("share_id" => share.key, "share_name" => "Marketing")
      expect(rows.find { |r| r["item"]&.dig("name") == "Leads" }["actor"]["id"]).to eq(owner.key)
    end

    it "filters by share, person, action and date range, and pages" do
      expect(events(share: sales.key).pluck("share_id").uniq).to eq([sales.key])
      expect(events(member: owner.key).map { |r| r["actor"]["id"] }.uniq).to eq([owner.key])
      expect(events(type: "renamed").pluck("action").uniq).to eq(["renamed"])
      old = events(to: 2.days.ago.to_date.iso8601)
      expect(old.map { |r| r["item"]["name"] }).to eq(["Brief"])
      today = events(from: Date.current.iso8601)
      expect(today.pluck("action")).to include("renamed")
      expect(today.find { |r| r["action"] == "created" && r.dig("item", "name") == "Brief" }).to be_nil
      get admin_path("/events"), params: { limit: 1 }, headers: admin_h
      expect(response.parsed_body["events"].size).to eq(1)
      expect(response.parsed_body["next_cursor"]).to eq("1")
    end

    it "refuses a bad filter and 404s another org's share or member" do
      get admin_path("/events"), params: { type: "exploded" }, headers: admin_h
      expect(response).to have_http_status(:unprocessable_content)
      get admin_path("/events"), params: { from: "yesterday" }, headers: admin_h
      expect(response).to have_http_status(:unprocessable_content)
      get admin_path("/events"), params: { share: foreign_share.key }, headers: admin_h
      expect(response).to have_http_status(:not_found)
      get admin_path("/events"), params: { member: create(:membership, organization: outsider_org).key }, headers: admin_h
      expect(response).to have_http_status(:not_found)
      get "/api/v1/orgs/#{outsider_org.key}/disk/admin/events", headers: admin_h
      expect(response).to have_http_status(:not_found)
    end

    it "loads a page of events in a fixed number of queries" do
      events
      before = query_count { events }
      5.times { |i| Disk::NodeOps.new(owner).create_folder(parent_key: sales.root_node.key, name: "More #{i}") }
      expect(query_count { events }).to eq(before)
    end

    def query_count(&)
      n = 0
      ActiveSupport::Notifications.subscribed(->(*) { n += 1 }, "sql.active_record", &)
      n
    end
  end

  describe "GET /admin/export" do
    it "lists unsealed files with presigned URLs and pages as markdown under D/, sealed ones as encrypted, and no C:\\ (not the org's)" do
      docs = make_folder(share.root_node, "Docs")
      file = make_stored_file(docs, "plan.pdf", size: 4, versions: [2])
      page = make_folder(docs, "Notes").tap { |n| n.update!(kind: Disk::Node::KIND_PAGE) }
      Disk::Page.for(page).update!(markdown: "# Notes")
      sealed = make_folder(docs, "x").tap do |n|
        n.update_columns(sealed: true, name: nil, metadata_ciphertext: "x", seal_scope_node_id: n.id)
      end
      personal = make_stored_file(c_root(member), "mine.pdf", size: 2)
      trashed = make_stored_file(docs, "old.pdf", size: 1)
      Disk::NodeOps.new(owner).trash(trashed)
      Disk::NodeOps.new(owner).grant(docs, member, "view")
      Disk::NodeOps.new(owner).create_link(file)

      get admin_path("/export"), headers: owner_h
      export = response.parsed_body["export"]
      entries = export["entries"].index_by { |e| e["id"] }
      expect(entries[file.key]).to include("path" => "D/Marketing/Docs/plan.pdf", "size_bytes" => 4, "included" => true)
      expect(entries[file.key]["url"]).to include(file.current_version.storage_key)
      expect(entries[page.key]).to include("path" => "D/Marketing/Docs/Notes.md", "markdown" => "# Notes")
      expect(entries[sealed.key]).to include("sealed" => true, "included" => false, "url" => nil,
                                             "path" => "D/Marketing/Docs/#{sealed.key} (sealed)", "scope_id" => sealed.key)
      expect(entries[file.key]["scope_id"]).to be_nil
      expect(entries).not_to have_key(trashed.key)
      expect(entries).not_to have_key(personal.key)
      manifest = export["manifest"]
      expect(manifest["note"]).to include("Trash and older versions are not included")
      expect(manifest["shares"].first).to include("name" => "Marketing", "folder" => "D/Marketing")
      expect(manifest["grants"].first).to include("role" => "view", "path" => "D/Marketing/Docs")
      expect(manifest["links"].first["path"]).to eq("D/Marketing/Docs/plan.pdf")
      expect(manifest["members"].map(&:keys).flatten).not_to include("folder") # no C/<member> in the export
      expect(manifest["members"].pluck("role")).to include("member")
      expect(export["next_cursor"]).to be_nil
    end
  end
end
