require "rails_helper"

# Listing additions for the web: share emblems matching the web set, people on
# the Access column without a hover fetch, and "modified today" in the caller's zone.
RSpec.describe "Disk listing extras", type: :request do
  include_context "disk org"
  include ActiveSupport::Testing::TimeHelpers

  let(:h) { auth_headers(member_user) }
  let(:root) { c_root(member) }

  describe "share emblems" do
    it "accepts the web's twelve, treats the old folder emblem as none, and refuses others" do
      %w[business legal engineering].each do |icon|
        post disk_path("/shares"), params: { name: icon, icon: icon }, headers: auth_headers(owner_user), as: :json
        expect(response).to have_http_status(:created)
      end
      expect(Disk::Share::ICONS.size).to eq(12)
      post disk_path("/shares"), params: { name: "Plain", icon: "folder" }, headers: auth_headers(owner_user), as: :json
      expect(response.parsed_body["share"]["icon"]).to be_nil
      post disk_path("/shares"), params: { name: "Bad", icon: "rocket" }, headers: auth_headers(owner_user), as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "404s another org's share" do
      patch disk_path("/shares/#{foreign_share.key}"), params: { icon: "legal" }, headers: auth_headers(owner_user),
                                                       as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "shared_with on listings" do
    let!(:folder) { make_folder(root, "Contracts") }
    let!(:inner) { make_folder(folder, "2026") }
    let!(:plain) { make_folder(root, "Plain") }

    before do
      [other, owner].each { |m| Disk::Grant.create!(organization: org, node: folder, membership: m, role: "view") }
    end

    def by_name(nodes) = nodes.index_by { |n| n["name"] }

    it "carries direct grants with names and roles, the total, and whether access is inherited" do
      get disk_path("/nodes/#{root.key}/children"), headers: h
      rows = by_name(response.parsed_body["nodes"])
      expect(rows["Contracts"]["shared_with"]).to include("total" => 2, "inherited" => false)
      expect(rows["Contracts"]["shared_with"]["people"].map { |p| [p["membership_id"], p["name"], p["role"]] })
        .to eq([[other.key, "Ola Other", "view"], [owner.key, "Olive Owner", "view"]])
      expect(rows["Contracts"]["shared_with"]["people"].first).to have_key("avatar_url")
      expect(rows["Plain"]["shared_with"]).to eq("people" => [], "total" => 0, "inherited" => false)

      get disk_path("/nodes/#{folder.key}/children"), headers: h
      expect(response.parsed_body["nodes"].first["shared_with"]).to include("total" => 0, "inherited" => true)

      share = make_share("Marketing")
      share.share_memberships.create!(organization: org, membership: member, role: "view")
      make_folder(share.root_node, "Launch")
      get disk_path("/nodes/#{share.root_node.key}/children"), headers: h
      expect(response.parsed_body["nodes"].first["shared_with"]["inherited"]).to be(true)

      get disk_path("/search"), params: { q: "contr" }, headers: h
      expect(response.parsed_body["results"].first["shared_with"]["total"]).to eq(2)
      get disk_path("/views/shared-with-me"), headers: auth_headers(other_user)
      expect(response.parsed_body["nodes"].first["shared_with"]["total"]).to eq(2)
    end

    it "shows at most four people and loads them in a constant number of queries" do
      count = lambda do
        n = 0
        counter = ->(*, payload) { n += 1 if payload[:sql].include?("disk_grants") }
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
          get disk_path("/nodes/#{root.key}/children"), headers: h
        end
        n
      end
      before = count.call
      6.times do |i|
        node = make_folder(root, "F#{i}")
        3.times { Disk::Grant.create!(organization: org, node: node, membership: create(:membership, organization: org), role: "edit") }
      end
      extra = Array.new(3) { create(:membership, organization: org) }
      extra.each { |m| Disk::Grant.create!(organization: org, node: folder, membership: m, role: "edit") }
      expect(count.call).to eq(before)
      contracts = by_name(response.parsed_body["nodes"])["Contracts"]["shared_with"]
      expect([contracts["people"].size, contracts["total"]]).to eq([4, 5])
    end
  end

  describe "modified=today with tz, and since" do
    let!(:fresh) { make_folder(root, "fresh", content_modified_at: Time.utc(2026, 10, 3, 23, 30)) }
    let!(:old) { make_folder(root, "old", content_modified_at: Time.utc(2026, 10, 3, 21, 0)) }

    around { |ex| travel_to(Time.utc(2026, 10, 3, 23, 45)) { ex.run } }

    def names(path, **params)
      get disk_path(path), params: params, headers: h
      (response.parsed_body["nodes"] || response.parsed_body["results"]).map { |n| n["name"] }
    end

    it "means since the start of the caller's local day, on children and search" do
      # 23:45 UTC is 01:45 on 4 October in Amsterdam: only the 23:30 UTC item is from today there.
      expect(names("/nodes/#{root.key}/children", modified: "today", tz: "Europe/Amsterdam")).to eq(%w[fresh])
      expect(names("/nodes/#{root.key}/children", modified: "today")).to contain_exactly("fresh", "old")
      expect(names("/search", q: "o", modified: "today", tz: "Europe/Amsterdam")).to eq([])
      expect(names("/search", q: "fresh", modified: "today", tz: "Europe/Amsterdam")).to eq(%w[fresh])
      expect(names("/nodes/#{root.key}/children", since: "2026-10-03T22:00:00Z")).to eq(%w[fresh])
      expect(names("/nodes/#{root.key}/children", modified: "7d")).to contain_exactly("fresh", "old")
    end

    it "refuses an unknown zone and a bad timestamp" do
      get disk_path("/nodes/#{root.key}/children"), params: { modified: "today", tz: "Mars/Olympus" }, headers: h
      expect(response).to have_http_status(:unprocessable_content)
      get disk_path("/search"), params: { q: "x", since: "yesterday" }, headers: h
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
