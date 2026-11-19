require "rails_helper"

# Shares belong to a team (2026-10-04): one org, one payer, several distinct
# companies on their own domains. An open share with a domain reaches only
# members who see that domain; names are unique per team.
RSpec.describe "Disk share teams", type: :request do
  include_context "disk org"

  let(:owner_h) { auth_headers(owner_user) }
  let(:member_h) { auth_headers(member_user) }
  let(:other_h) { auth_headers(other_user) }
  let!(:main) { create(:domain, organization: org, name: "main.test") }
  let!(:lalaaji) { create(:domain, organization: org, name: "lalaaji.test") }

  before do
    # member works at lalaaji only; other only at main.
    member.update!(all_domains: false)
    MembershipDomain.create!(membership: member, domain: lalaaji)
    other.update!(all_domains: false)
    MembershipDomain.create!(membership: other, domain: main)
  end

  def share_names(headers)
    get disk_path("/shares"), headers: headers
    response.parsed_body["shares"].map { |s| s["name"] }
  end

  it "opens a team's share only to members who see its domain" do
    post disk_path("/shares"), params: { name: "Lalaaji files", openness: "org", domain_id: lalaaji.key }, headers: owner_h, as: :json
    expect(response).to have_http_status(:created)
    share = response.parsed_body["share"]
    expect(share["domain"]).to eq("id" => lalaaji.key, "name" => "lalaaji.test")
    post disk_path("/shares"), params: { name: "Everyone", openness: "org" }, headers: owner_h, as: :json
    expect(response.parsed_body["share"]["domain"]).to be_nil

    expect(share_names(member_h)).to contain_exactly("Lalaaji files", "Everyone")
    expect(share_names(other_h)).to contain_exactly("Everyone")
    expect(share_names(owner_h)).to contain_exactly("Lalaaji files", "Everyone")

    root = Disk::Share.find_by(key: share["id"]).root_node
    get disk_path("/nodes/#{root.key}"), headers: other_h
    expect(response).to have_http_status(:not_found)
    get disk_path("/nodes/#{root.key}"), headers: member_h
    expect(response).to have_http_status(:ok)
  end

  it "still reaches an assigned member outside the team" do
    s = make_share("Lalaaji only", openness: "org", domain: lalaaji)
    Disk::ShareMembership.create!(organization: org, share: s, membership: other, role: "view")
    expect(share_names(other_h)).to include("Lalaaji only")
  end

  it "keeps names unique per team, not per org, and moves a share between teams" do
    post disk_path("/shares"), params: { name: "Marketing", domain_id: main.key }, headers: owner_h, as: :json
    post disk_path("/shares"), params: { name: "Marketing", domain_id: lalaaji.key }, headers: owner_h, as: :json
    expect(response).to have_http_status(:created)
    id = response.parsed_body["share"]["id"]
    patch disk_path("/shares/#{id}"), params: { domain_id: "" }, headers: owner_h, as: :json
    expect(response.parsed_body["share"]["domain"]).to be_nil
    post disk_path("/shares"), params: { name: "Marketing", domain_id: main.key }, headers: owner_h, as: :json
    expect(response).not_to have_http_status(:created)
  end

  it "creates templates for one team" do
    post disk_path("/shares/templates"), params: { names: %w[Sales HR], domain_id: lalaaji.key }, headers: owner_h, as: :json
    post disk_path("/shares/templates"), params: { names: %w[Sales] }, headers: owner_h, as: :json
    expect(Disk::Share.where(name: "Sales").pluck(:domain_id)).to contain_exactly(lalaaji.id, nil)
  end

  it "refuses another org's domain" do
    foreign = create(:domain, organization: outsider_org)
    post disk_path("/shares"), params: { name: "X", domain_id: foreign.key }, headers: owner_h, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it "makes a removed domain's shares members-only instead of opening them to the org" do
    open = make_share("Marketing", openness: "org", domain: lalaaji)
    make_share("Marketing", openness: "org")
    lalaaji.destroy!
    expect(open.reload).to have_attributes(domain_id: nil, openness: "assigned", name: "Marketing (lalaaji.test)")
    expect(share_names(member_h)).to contain_exactly("Marketing")
  end

  it "numbers a released share whose name with the domain is taken too" do
    open = make_share("Marketing", openness: "org", domain: lalaaji)
    make_share("Marketing", openness: "org")
    make_share("Marketing (lalaaji.test)", openness: "org")
    lalaaji.destroy!
    expect(open.reload.name).to eq("Marketing (lalaaji.test) 2")
  end
end
