require "rails_helper"

RSpec.describe "Api::V1::Disk::Search", type: :request do
  include_context "disk org"

  let(:share) { make_share("Marketing", openness: "org") }
  let(:launch) { make_folder(share.root_node, "Launch") }
  let!(:hero) { make_file(make_folder(launch, "Assets"), "hero.png", mime: "image/png") }
  let!(:my_hero) { make_file(c_root(member), "hero-notes.md", mime: "text/markdown") }
  let!(:their_hero) { make_file(c_root(other), "hero-private.md", mime: "text/markdown") }

  it "finds matches everywhere I can see with their paths, never another member's C:\\" do
    get disk_path("/search?q=HERO"), headers: auth_headers(member_user)
    expect(response).to have_http_status(:ok)
    results = response.parsed_body["results"]
    expect(results.map { |r| r["name"] }).to eq(%w[hero-notes.md hero.png])
    expect(results.last["path"].map { |s| s["name"] }).to eq(%w[Marketing Launch Assets hero.png])
  end

  it "searches from a folder downward when scoped" do
    get disk_path("/search?q=hero&scope=#{launch.key}"), headers: auth_headers(member_user)
    expect(response.parsed_body["results"].map { |r| r["id"] }).to eq([hero.key])
  end

  it "includes items shared with me, and leaves sealed nodes out" do
    Disk::Grant.create!(organization: org, node: their_hero, membership: member, role: "view")
    hero.update_columns(sealed: true, name: nil, mime: nil, metadata_ciphertext: "x")
    get disk_path("/search?q=hero"), headers: auth_headers(member_user)
    expect(response.parsed_body["results"].map { |r| r["name"] }).to eq(%w[hero-notes.md hero-private.md])
  end

  it "refuses an empty query" do
    get disk_path("/search?q=%20"), headers: auth_headers(member_user)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "404s a scope in another org" do
    get disk_path("/search?q=hero&scope=#{foreign_node.key}"), headers: auth_headers(owner_user)
    expect(response).to have_http_status(:not_found)
  end
end
