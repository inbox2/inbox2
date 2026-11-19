require "rails_helper"

# Private labels (docs/plans/mail-import.md D11/D12): a member's own tags, seen
# and changed by them alone, beside the team's.
RSpec.describe "Private labels", type: :request do
  let(:admin_user) { create(:user) }
  let(:org) { create(:organization, owner: admin_user) }
  let!(:admin) { create(:membership, user: admin_user, organization: org, role: "owner") }
  let(:ana_user) { create(:user) }
  let!(:ana) { create(:membership, user: ana_user, organization: org, role: "member") }
  let(:bob_user) { create(:user) }
  let!(:bob) { create(:membership, user: bob_user, organization: org, role: "member") }
  let(:conv) { create(:conversation, organization: org, domain: org.default_domain) }
  let(:team_tag) { org.tags.create!(name: "Clients", color: "#123456") }
  let(:anas) { org.tags.create!(name: "Mine", color: "#654321", membership: ana) }
  let(:tags_path) { "/api/v1/orgs/#{org.key}/tags" }

  def conv_json(user)
    get "/api/v1/orgs/#{org.key}/conversations/#{conv.key}", headers: auth_headers(user)
    response.parsed_body.dig("conversation", "tags") || response.parsed_body["tags"]
  end

  it "lets any member make one, and lists it to them alone beside the team's" do
    team_tag
    post tags_path, params: { name: "Leads", private: true }, headers: auth_headers(ana_user), as: :json
    expect(response).to have_http_status(:created)
    expect(response.parsed_body["tag"]).to include("name" => "Leads", "private" => true)

    get tags_path, headers: auth_headers(ana_user)
    expect(response.parsed_body["tags"].map { |t| [t["name"], t["private"]] }).to include(["Leads", true], ["Clients", false])
    get tags_path, headers: auth_headers(bob_user)
    expect(response.parsed_body["tags"].count { |t| t["private"] }).to eq(0)
  end

  it "leaves the team's names to the team, since lists filter by name" do
    team_tag
    post tags_path, params: { name: "clients", private: true }, headers: auth_headers(ana_user), as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "keeps the priority names for priority" do
    post tags_path, params: { name: "urgent", private: true }, headers: auth_headers(ana_user), as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "still needs an admin for a team tag" do
    post tags_path, params: { name: "Team" }, headers: auth_headers(ana_user), as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "shows a label on a conversation to its owner only, and a full replace keeps the others' labels" do
    conv.tags << [team_tag, anas]

    expect(conv_json(bob_user).map { |t| t["name"] }).to eq(["Clients"])
    put "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/tags", params: { tag_ids: [] },
                                                                 headers: auth_headers(bob_user), as: :json

    expect(conv.reload.tags).to contain_exactly(anas)
    expect(conv_json(ana_user).map { |t| [t["name"], t["private"]] }).to eq([["Mine", true]])
  end

  it "does not let another member apply, rename or delete it" do
    put "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/tags", params: { add_tag_ids: [anas.key] },
                                                                 headers: auth_headers(bob_user), as: :json
    expect(conv.reload.tags).to be_empty

    patch "#{tags_path}/#{anas.key}", params: { name: "Renamed" }, headers: auth_headers(admin_user), as: :json
    expect(response).to have_http_status(:not_found)
    delete "#{tags_path}/#{anas.key}", headers: auth_headers(bob_user)
    expect(response).to have_http_status(:not_found)

    patch "#{tags_path}/#{anas.key}", params: { name: "Renamed" }, headers: auth_headers(ana_user), as: :json
    expect(anas.reload.name).to eq("Renamed")
  end

  it "filters the list by the member's own label" do
    conv.tags << anas
    get "/api/v1/orgs/#{org.key}/conversations", params: { tags: ["Mine"] }, headers: auth_headers(ana_user)
    expect(response.parsed_body["conversations"].map { |c| c["id"] }).to eq([conv.key])

    get "/api/v1/orgs/#{org.key}/conversations", params: { tags: ["Mine"] }, headers: auth_headers(bob_user)
    expect(response.parsed_body["conversations"]).to be_empty
  end

  it "shares with the team only through an owner or admin who owns it" do
    mine = org.tags.create!(name: "Leads", color: "#111111", membership: admin)
    post "#{tags_path}/#{anas.key}/share", headers: auth_headers(ana_user)
    expect(response).to have_http_status(:forbidden)

    post "#{tags_path}/#{mine.key}/share", headers: auth_headers(admin_user)
    expect(response).to have_http_status(:ok)
    expect(mine.reload.membership_id).to be_nil
  end
end
