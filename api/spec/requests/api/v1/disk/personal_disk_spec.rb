require "rails_helper"

# C:\ is the person's own, the same from every team, held in a hidden personal
# workspace; each team gets a drive letter (decided 2026-10-07).
RSpec.describe "Disk personal C:\\ and drive letters", type: :request do
  include_context "disk org"

  let(:second_org) { create(:organization, name: "Second Co", owner: owner_user) }
  let!(:second) { create(:membership, user: member_user, organization: second_org, role: "member") }
  let(:member_h) { auth_headers(member_user) }

  before { create(:subscription, organization: second_org, plan: Plan.max) }

  def second_path(path = "") = "/api/v1/orgs/#{second_org.key}/disk#{path}"

  it "shows the same C:\\ from every team, its own quota from the best tier, and this team's letter" do
    get disk_path, headers: member_h
    first = response.parsed_body
    get second_path, headers: member_h
    again = response.parsed_body
    expect(again["c_drive"]["id"]).to eq(first["c_drive"]["id"])
    expect(first["drive_letter"]).to eq("D")
    expect(again["drive_letter"]).to eq("E")
    # 30 GB: one member's share of the max tier, the best among the person's teams.
    expect(first["c_quota"]).to include("pool_bytes" => 30.gigabytes, "used_bytes" => 0)
    expect(first["quota"]["pool_bytes"]).to eq(org.disk_quota_bytes)
  end

  it "keeps the personal workspace out of the account's org list, and letters stay put when a team is left" do
    c_root(member)
    get "/api/v1/account", headers: member_h
    orgs = response.parsed_body["organizations"]
    expect(orgs.map { |o| o["id"] }).to contain_exactly(org.key, second_org.key)
    expect(orgs.to_h { |o| [o["id"], o["drive_letter"]] }).to eq(org.key => "D", second_org.key => "E")

    member.destroy!
    third = create(:membership, user: member_user, organization: create(:organization, owner: owner_user))
    expect(second.reload.drive_letter).to eq("E")
    expect(third.drive_letter).to eq("D")
  end

  it "charges a C:\\ upload to the person, not the team, and moves the bytes when a file goes into a share" do
    file = make_stored_file(make_folder(c_root(member), "Clients"), "deal.pdf", size: 9, versions: [4])
    personal = member_user.personal_organization
    expect([personal.reload.disk_bytes_used, org.reload.disk_bytes_used]).to eq([13, 0])

    share = make_share("Open", openness: "org", org_role: "edit")
    post disk_path("/nodes/#{file.key}/move"), params: { target_id: share.root_node.key }, headers: member_h, as: :json
    expect(response).to have_http_status(:ok)
    expect(file.reload).to have_attributes(organization_id: org.id, share_id: share.id, custodian_membership_id: nil)
    expect(file.versions.pluck(:organization_id).uniq).to eq([org.id])
    expect([personal.reload.disk_bytes_used, org.reload.disk_bytes_used]).to eq([0, 13])

    # Not enough room on the team: the move is refused before anything changes.
    post disk_path("/nodes/#{file.key}/move"), params: { target_id: c_root(member).key }, headers: member_h, as: :json
    expect(response).to have_http_status(:ok)
    org.update!(disk_quota_override_gb: 1, disk_bytes_used: 1.gigabyte - 1)
    big = make_stored_file(c_root(member), "big.pdf", size: 5)
    post disk_path("/nodes/#{big.key}/move"), params: { target_id: share.root_node.key }, headers: member_h, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include("code" => "disk_quota_exceeded")
    expect(big.reload.organization_id).to eq(personal.id)
  end

  it "reaches a folder shared from a C:\\ by a colleague in one team, and a sealed C:\\ folder from another team" do
    folder = make_folder(c_root(member), "Handover")
    Disk::NodeOps.new(member).grant(folder, other, "view")
    get disk_path("/views/shared-with-me"), headers: auth_headers(other_user)
    expect(response.parsed_body["nodes"].pluck("id")).to eq([folder.key])
    get disk_path("/nodes/#{folder.key}/children"), headers: auth_headers(other_user)
    expect(response).to have_http_status(:ok)

    vault = make_sealed_folder(member)
    get second_path("/scopes/#{vault.key}"), headers: member_h
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["scope"]["grant"]).to include("epoch" => 1)
    get disk_path("/views/starred"), headers: member_h
    expect(response.parsed_body["nodes"]).to eq([])
    patch second_path("/nodes/#{folder.key}"), params: { starred: true }, headers: member_h, as: :json
    get disk_path("/views/starred"), headers: member_h
    expect(response.parsed_body["nodes"].pluck("id")).to eq([folder.key])
  end
end
