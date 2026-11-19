require "rails_helper"

# Spec F4 public links, unsealed half (package 6).
RSpec.describe "Api::V1::Disk::Links", type: :request do
  include_context "disk org"

  let(:share) { make_share("Marketing") }
  let(:folder) { make_folder(share.root_node, "Launch") }
  let!(:inner) { make_folder(folder, "Assets") }
  let!(:file) { make_stored_file(inner, "brief.pdf", size: 10) }
  let!(:outside) { make_stored_file(share.root_node, "budget.pdf", size: 5) }

  def create_link(node, user: owner_user, **params)
    post disk_path("/nodes/#{node.key}/links"), params: params, headers: auth_headers(user), as: :json
    response.parsed_body["link"]
  end

  def pub(token, path = "") = "/api/v1/disk/links/#{token}#{path}"

  describe "managing links" do
    it "creates a link whose token is returned once and stored only as a digest" do
      link = create_link(folder, password: "hunter22", expires_at: 2.days.from_now.iso8601, hide_download: true)
      expect(response).to have_http_status(:created)
      expect(link).to include("node_id" => folder.key, "has_password" => true, "hide_download" => true,
                              "expired" => false)
      expect(link["id"]).to start_with("dln_")
      expect(link["url"]).to end_with("/share/#{folder.name.parameterize}/#{link['token']}")
      expect(link["token"]).to match(/\A[A-Za-z0-9]{22}\z/)
      row = Disk::Link.find_by!(key: link["id"])
      expect(row.token_digest).to eq(Digest::SHA256.hexdigest(link["token"]))
      expect(row.password_verifier_digest).to start_with("$2")
      expect(Disk::Event.find_by(action: "link_created", link_id: row.id)).to be_present

      get disk_path("/nodes/#{folder.key}/links"), headers: auth_headers(owner_user)
      expect(response.parsed_body["links"].map { |l| [l["id"], l["token"], l["url"]] }).to eq([[link["id"], nil, nil]])
    end

    it "refuses non-managers, past expiry, roots, sealed items and orgs with links off" do
      share.share_memberships.create!(organization: org, membership: member, role: "edit")
      create_link(folder, user: member_user)
      expect(response).to have_http_status(:forbidden)
      get disk_path("/nodes/#{folder.key}/links"), headers: auth_headers(member_user)
      expect(response).to have_http_status(:forbidden)

      create_link(folder, expires_at: 1.hour.ago.iso8601)
      expect(response).to have_http_status(:unprocessable_content)
      create_link(share.root_node)
      expect(response).to have_http_status(:unprocessable_content)
      create_link(folder, password: "x" * 73)
      expect(response).to have_http_status(:unprocessable_content)

      create_link(make_sealed_node(make_sealed_share.root_node))
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"].first["message"]).to match(/no public links/)

      org.update!(disk_links_enabled: false)
      create_link(folder)
      expect(response).to have_http_status(:forbidden)
      get disk_path("/"), headers: auth_headers(owner_user)
      expect(response.parsed_body["settings"]).to include("links_enabled" => false)
    end

    it "revokes a link; it then 404s for visitors and leaves the list" do
      link = create_link(file)
      delete disk_path("/links/#{link['id']}"), headers: auth_headers(owner_user)
      expect(response).to have_http_status(:no_content)
      get pub(link["token"])
      expect(response).to have_http_status(:not_found)
      get disk_path("/nodes/#{file.key}/links"), headers: auth_headers(owner_user)
      expect(response.parsed_body["links"]).to eq([])
    end

    it "404s another org's node and link, and a link the caller cannot see" do
      create_link(foreign_node)
      expect(response).to have_http_status(:not_found)
      get disk_path("/nodes/#{foreign_node.key}/links"), headers: auth_headers(owner_user)
      expect(response).to have_http_status(:not_found)
      theirs = Disk::Link.create!(organization: outsider_org, node: foreign_node, token_digest: "d1")
      delete disk_path("/links/#{theirs.key}"), headers: auth_headers(owner_user)
      expect(response).to have_http_status(:not_found)

      mine = Disk::Link.create!(organization: org, node: make_folder(c_root(owner), "Private"), token_digest: "d2")
      delete disk_path("/links/#{mine.key}"), headers: auth_headers(member_user)
      expect(response).to have_http_status(:not_found)
    end

    it "revokes a share's links when the share is deleted, and purging removes them" do
      link = create_link(file)
      delete disk_path("/shares/#{share.key}"), params: { confirm_name: "Marketing" }, headers: auth_headers(owner_user),
                                                as: :json
      expect(Disk::Link.find_by!(key: link["id"]).revoked_at).to be_present
      post disk_path("/shares/#{share.key}/restore"), headers: auth_headers(owner_user)
      get pub(link["token"])
      expect(response).to have_http_status(:not_found)

      delete disk_path("/shares/#{share.key}"), params: { confirm_name: "Marketing" }, headers: auth_headers(owner_user),
                                                as: :json
      delete disk_path("/shares/#{share.key}/purge"), headers: auth_headers(owner_user)
      expect(response).to have_http_status(:no_content)
      expect(Disk::Link.where(key: link["id"])).to be_empty
    end

    it "deletes a file's links when it is purged, keeping the events" do
      create_link(file)
      Disk::Event.record!(Disk::Event::ACTION_LINK_USED, actor: nil, node: file, link: Disk::Link.last)
      ops = Disk::NodeOps.new(owner)
      ops.purge(ops.trash(file))
      expect(Disk::Link.count).to eq(0)
      expect(Disk::Event.where(action: "link_used").pluck(:link_id, :node_id)).to eq([[nil, nil]])
    end
  end

  describe "visiting a link" do
    it "shows a file link and hands out a download and a preview URL, recording the use" do
      token = create_link(file)["token"]
      get pub(token)
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["link"]).to include("password_required" => false, "unlocked" => true, "download_allowed" => true)
      expect(body["link"]["abuse_email"]).to be_present
      expect(body["link"]["node"]).to include("id" => file.key, "name" => "brief.pdf", "kind" => "file", "size_bytes" => 10)

      get pub(token, "/download")
      expect(response).to have_http_status(:ok)
      dl = response.parsed_body["download"]
      expect(dl["url"]).to include("attachment=brief.pdf")
      expect(dl["preview_url"]).to include("inline")
      event = Disk::Event.find_by!(action: "link_used")
      expect([event.node_id, event.actor_membership_id, event.link.key]).to eq([file.id, nil, Disk::Link.last.key])
      expect(Disk::Link.last.last_used_at).to be_present
    end

    it "with hide_download, gives a preview URL and no download URL" do
      token = create_link(file, hide_download: true)["token"]
      get pub(token)
      expect(response.parsed_body["link"]["download_allowed"]).to be(false)
      get pub(token, "/download")
      expect(response.parsed_body["download"]["url"]).to be_nil
      expect(response.parsed_body["download"]["preview_url"]).to be_present
    end

    it "lists a folder link's subtree, and never anything outside it" do
      token = create_link(folder)["token"]
      get pub(token)
      body = response.parsed_body
      expect(body["folder"]["id"]).to eq(folder.key)
      expect(body["nodes"].map { |n| n["name"] }).to eq(["Assets"])

      get pub(token), params: { node_id: inner.key }
      body = response.parsed_body
      expect(body["path"].map { |n| n["name"] }).to eq(%w[Launch Assets])
      expect(body["nodes"].map { |n| n["id"] }).to eq([file.key])
      get pub(token, "/download"), params: { node_id: file.key }
      expect(response).to have_http_status(:ok)

      # Subtree escape: the share root, a sibling file, another org's node.
      [share.root_node, outside, foreign_node].each do |n|
        get pub(token), params: { node_id: n.key }
        expect(response).to have_http_status(:not_found)
        get pub(token, "/download"), params: { node_id: n.key }
        expect(response).to have_http_status(:not_found)
      end
      get pub(token, "/download")
      expect(response).to have_http_status(:not_found) # the folder itself has no bytes
    end

    it "needs the password before it names the item or serves bytes" do
      token = create_link(file, password: "hunter22")["token"]
      get pub(token)
      expect(response.parsed_body["link"]).to include("password_required" => true, "unlocked" => false, "node" => nil)
      get pub(token, "/download")
      expect(response).to have_http_status(:forbidden)

      post pub(token, "/unlock"), params: { password: "wrong" }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["errors"].first["message"]).to eq("Wrong password")

      post pub(token, "/unlock"), params: { password: "hunter22" }, as: :json
      unlock = response.parsed_body["unlock"]["token"]
      headers = { "X-Disk-Link-Unlock" => unlock }
      get pub(token), headers: headers
      expect(response.parsed_body["link"]["node"]["name"]).to eq("brief.pdf")
      get pub(token, "/download"), headers: headers
      expect(response).to have_http_status(:ok)

      other = create_link(outside, password: "hunter22")["token"]
      get pub(other, "/download"), headers: headers # an unlock is for one link only
      expect(response).to have_http_status(:forbidden)
    end

    it "answers revoked, expired, trashed, disabled and unknown links with the same 404" do
      tokens = Array.new(5) { create_link(file)["token"] }
      Disk::Link.find_by!(token_digest: Disk::Link.digest(tokens[0])).update!(revoked_at: Time.current)
      Disk::Link.find_by!(token_digest: Disk::Link.digest(tokens[1])).update!(expires_at: 1.minute.ago)
      expired_body = nil
      get pub(tokens[1])
      expired_body = response.body
      get pub("nope")
      expect(response.body).to eq(expired_body)

      bodies = [tokens[0], tokens[1], "nope"].map do |t|
        get pub(t)
        expect(response).to have_http_status(:not_found)
        response.body
      end
      Disk::NodeOps.new(owner).trash(inner)
      get pub(tokens[2])
      bodies << response.body
      Disk::NodeOps.new(owner).restore(inner)
      get pub(tokens[2])
      expect(response).to have_http_status(:ok)

      org.update!(disk_links_enabled: false)
      get pub(tokens[3])
      bodies << response.body
      org.update!(disk_links_enabled: true)
      org.subscription.update!(plan: Plan.free)
      org.update!(disk_lost_at: 31.days.ago) # past the read-only month
      get pub(tokens[4], "/download")
      bodies << response.body
      expect(bodies.uniq).to eq([expired_body])
    end

    it "rate limits wrong passwords" do
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      token = create_link(file, password: "hunter22")["token"]
      statuses = Array.new(11) do
        post pub(token, "/unlock"), params: { password: "guess" }, as: :json
        response.status
      end
      expect(statuses.first(10).uniq).to eq([403])
      expect(statuses.last).to eq(429)
      post pub(token, "/unlock"), params: { password: "hunter22" }, as: :json
      expect(response).to have_http_status(:too_many_requests)
    ensure
      Rack::Attack.cache.store = Rails.cache
    end
  end
end
