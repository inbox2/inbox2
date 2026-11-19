require "rails_helper"

RSpec.describe "Api::V1::Disk::Grants", type: :request do
  include_context "disk org"

  let(:mine) { make_folder(c_root(member), "Contracts") }
  let!(:inner) { make_folder(mine, "2026") }
  let(:grants_path) { disk_path("/nodes/#{mine.key}/grants") }

  it "shares a folder by name: the grantee sees it in Shared with me and reaches beneath it, not above" do
    put "#{grants_path}/#{other.key}", params: { role: "view" }, headers: auth_headers(member_user), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["grant"]).to include("role" => "view", "node_id" => mine.key)
    expect(response.parsed_body["grant"]["id"]).to start_with("dgr_")

    other_h = auth_headers(other_user)
    get disk_path("/views/shared-with-me"), headers: other_h
    expect(response.parsed_body["nodes"].map { |n| n["id"] }).to eq([mine.key])
    get disk_path("/nodes/#{inner.key}"), headers: other_h
    expect(response).to have_http_status(:ok)
    get disk_path("/nodes/#{c_root(member).key}"), headers: other_h
    expect(response).to have_http_status(:not_found)
  end

  it "lists, changes and removes grants; removal makes the item vanish for the grantee" do
    Disk::Grant.create!(organization: org, node: mine, membership: other, role: "view")
    get grants_path, headers: auth_headers(member_user)
    expect(response.parsed_body["grants"].map { |g| g["membership"]["id"] }).to eq([other.key])

    put "#{grants_path}/#{other.key}", params: { role: "edit" }, headers: auth_headers(member_user), as: :json
    expect(Disk::Grant.find_by(node: mine, membership: other).role).to eq("edit")

    delete "#{grants_path}/#{other.key}", headers: auth_headers(member_user)
    expect(response).to have_http_status(:no_content)
    get disk_path("/views/shared-with-me"), headers: auth_headers(other_user)
    expect(response.parsed_body["nodes"]).to eq([])
  end

  it "refuses an editor granting, manage as a grant role, and a sealed node" do
    Disk::Grant.create!(organization: org, node: mine, membership: other, role: "edit")
    put "#{grants_path}/#{owner.key}", params: { role: "view" }, headers: auth_headers(other_user), as: :json
    expect(response).to have_http_status(:forbidden)
    put "#{grants_path}/#{owner.key}", params: { role: "manage" }, headers: auth_headers(member_user), as: :json
    expect(response).to have_http_status(:unprocessable_content)
    mine.update_columns(sealed: true, name: nil, metadata_ciphertext: "x")
    put "#{grants_path}/#{owner.key}", params: { role: "view" }, headers: auth_headers(member_user), as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "404s a node the caller cannot see, another org's node and another org's member" do
    get grants_path, headers: auth_headers(owner_user)
    expect(response).to have_http_status(:not_found)
    get disk_path("/nodes/#{foreign_node.key}/grants"), headers: auth_headers(owner_user)
    expect(response).to have_http_status(:not_found)
    outsider = create(:membership, organization: outsider_org)
    put "#{grants_path}/#{outsider.key}", params: { role: "view" }, headers: auth_headers(member_user), as: :json
    expect(response).to have_http_status(:not_found)
    delete "#{grants_path}/#{outsider.key}", headers: auth_headers(member_user)
    expect(response).to have_http_status(:not_found)
  end
end
