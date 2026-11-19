require "rails_helper"

# Owners and admins scope an agent's Disk reach (build guide 9c).
RSpec.describe "Disk agent grants", type: :request do
  include_context "disk org"

  let(:owner_h) { auth_headers(owner_user) }
  let(:share) { make_share("Marketing") }
  let(:folder) { make_folder(share.root_node, "Docs") }
  let(:agent) do
    m = create(:membership, user: create(:user), organization: org, role: "member", member_type: Membership::TYPE_AGENT)
    create(:agent, organization: org, membership: m, name: "Scribe")
  end

  def path(node = folder, a = agent) = disk_path("/agents/#{a.key}/grants/#{node.key}")

  it "grants, lists, changes and removes" do
    put path, params: { role: "view" }, headers: owner_h, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["grant"]).to include("role" => "view", "agent_id" => agent.key)
    expect(response.parsed_body["grant"]["node"]).to include("id" => folder.key)

    put path, params: { role: "edit" }, headers: owner_h, as: :json
    get disk_path("/agents/#{agent.key}/grants"), headers: owner_h
    expect(response.parsed_body["grants"].map { |g| [g["node"]["id"], g["role"]] }).to eq([[folder.key, "edit"]])
    expect(Disk::Event.where(node: folder).pluck(:action)).to include("agent_granted")

    delete path, headers: owner_h
    expect(response).to have_http_status(:no_content)
    expect(agent.disk_grants).to be_empty
  end

  it "lets admins grant and refuses plain members" do
    admin = create(:membership, user: create(:user), organization: org, role: "admin")
    put path, params: { role: "view" }, headers: auth_headers(admin.user), as: :json
    expect(response).to have_http_status(:ok)
    put path, params: { role: "view" }, headers: auth_headers(member_user), as: :json
    expect(response).to have_http_status(:forbidden)
    get disk_path("/agents/#{agent.key}/grants"), headers: auth_headers(member_user)
    expect(response).to have_http_status(:forbidden)
  end

  it "refuses a bad role, a sealed node, and anything the granter cannot reach" do
    put path, params: { role: "manage" }, headers: owner_h, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    put path(make_sealed_node(make_sealed_share.root_node)), params: { role: "view" }, headers: owner_h, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    put path(make_folder(c_root(member), "Mine")), params: { role: "view" }, headers: owner_h, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it "is not found across tenants" do
    put path(foreign_node), params: { role: "view" }, headers: owner_h, as: :json
    expect(response).to have_http_status(:not_found)
    theirs = create(:agent, organization: outsider_org)
    put path(folder, theirs), params: { role: "view" }, headers: owner_h, as: :json
    expect(response).to have_http_status(:not_found)
  end
end
