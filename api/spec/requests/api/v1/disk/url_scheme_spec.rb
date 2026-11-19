require "rails_helper"

# The Disk URL scheme (decided 2026-10-03): share slugs, node short ids, the
# ancestor chain on node detail, and in-app and public link URLs.
RSpec.describe "Disk URL scheme", type: :request do
  include_context "disk org"

  let(:owner_h) { auth_headers(owner_user) }

  describe "share slugs" do
    it "derives a unique slug from the name, follows renames and resolves shares by slug" do
      post disk_path("/shares"), params: { name: "Brand & Design" }, headers: owner_h, as: :json
      first = response.parsed_body["share"]
      expect(first["slug"]).to eq("brand-design")
      post disk_path("/shares"), params: { name: "Brand Design" }, headers: owner_h, as: :json
      expect(response.parsed_body["share"]["slug"]).to eq("brand-design-2")

      patch disk_path("/shares/brand-design"), params: { name: "Logos" }, headers: owner_h, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["share"]).to include("id" => first["id"], "slug" => "logos")
      get disk_path("/shares/logos/members"), headers: owner_h
      expect(response).to have_http_status(:ok)
      get disk_path("/shares/nope/members"), headers: owner_h
      expect(response).to have_http_status(:not_found)
    end

    it "does not resolve another org's slug" do
      make_share("Theirs", organization: outsider_org)
      get disk_path("/shares/theirs/members"), headers: owner_h
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "node short ids and the ancestor chain" do
    let(:share) { make_share("Marketing") }
    let(:brand) { make_folder(share.root_node, "Brand") }
    let(:logos) { make_folder(brand, "Logos") }

    it "exposes short_id, accepts it wherever a node id goes, and returns the chain" do
      get disk_path("/nodes/#{logos.short_id}"), headers: owner_h
      expect(response).to have_http_status(:ok)
      node = response.parsed_body["node"]
      expect(node["short_id"]).to eq(logos.key.delete_prefix("dnd_"))
      expect(node["path"].map { |p| [p["name"], p["short_id"], p["kind"]] })
        .to eq([["Marketing", share.root_node.short_id, "folder"], ["Brand", brand.short_id, "folder"],
                ["Logos", logos.short_id, "folder"]])
      expect(node["path"].first["share_slug"]).to eq("marketing")
      get disk_path("/nodes/#{brand.short_id}/children"), headers: owner_h
      expect(response.parsed_body["nodes"].pluck("id")).to eq([logos.key])
      get disk_path("/nodes/#{foreign_node.short_id}"), headers: owner_h
      expect(response).to have_http_status(:not_found)
    end

    it "builds in-app paths, cut to what the viewer sees" do
      expect(Disk::WebPath.for(logos)).to eq("/disk/d/marketing/Brand/Logos-#{logos.short_id}")
      mine = make_folder(make_folder(c_root(member), "Clients"), "Invoices")
      expect(Disk::WebPath.for(mine, viewer: member)).to eq("/disk/c/Clients/Invoices-#{mine.short_id}")
      expect(Disk::WebPath.for(mine, viewer: other)).to eq("/disk/shared/Invoices-#{mine.short_id}")
      expect(Disk::WebPath.for(share.root_node)).to eq("/disk/d/marketing")
      expect(Disk::WebPath.org_home(org.slug)).to eq("/disk?org=#{org.slug}")
      expect(Disk::WebPath.org_home("a b", "import")).to eq("/disk/import?org=a%20b")
    end

    it "makes absolute links on the web app, or at the root of Disk's own host" do
      with_env = lambda do |vars, &blk|
        old = vars.keys.to_h { |k| [k, ENV[k]] }
        vars.each { |k, v| ENV[k] = v }
        blk.call
      ensure
        old.each { |k, v| ENV[k] = v }
      end
      with_env.call("WEB_APP_URL" => "https://mail.example", "DISK_APP_URL" => nil) do
        expect(Disk::WebPath.url("/disk/c/x")).to eq("https://mail.example/disk/c/x")
      end
      with_env.call("WEB_APP_URL" => "https://mail.example", "DISK_APP_URL" => "https://disk.example/") do
        expect(Disk::WebPath.url("/disk/c/x")).to eq("https://disk.example/c/x")
        expect(Disk::WebPath.url("/disk?org=a")).to eq("https://disk.example/?org=a")
        expect(Disk::WebPath.url("/disk")).to eq("https://disk.example/")
        expect(Disk::WebPath.public_link(logos, "tok")).to eq("https://disk.example/share/logos/tok")
      end
    end
  end
end
