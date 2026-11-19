require "rails_helper"

RSpec.describe "Api::V1::Disk::ShareMembers", type: :request do
  include_context "disk org"

  let(:share) { make_share("Marketing") }
  let(:members_path) { disk_path("/shares/#{share.key}/members") }

  before { Disk::ShareMembership.create!(organization: org, share: share, membership: member, role: "manage") }

  it "lists members for anyone in the share" do
    get members_path, headers: auth_headers(member_user)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["members"]).to eq([{ "role" => "manage", "membership_id" => member.key,
                                                     "name" => "Mo Member" }])
  end

  it "lets a manager add, change and remove a member, and records each" do
    put "#{members_path}/#{other.key}", params: { role: "view" }, headers: auth_headers(member_user), as: :json
    expect(response).to have_http_status(:ok)
    put "#{members_path}/#{other.key}", params: { role: "edit" }, headers: auth_headers(member_user), as: :json
    expect(share.share_memberships.find_by(membership: other).role).to eq("edit")
    delete "#{members_path}/#{other.key}", headers: auth_headers(member_user)
    expect(response).to have_http_status(:no_content)
    expect(Disk::Event.where(share: share).pluck(:action)).to eq(%w[member_added member_changed member_removed])
  end

  it "refuses a viewer and a bad role" do
    share.share_memberships.find_by(membership: member).update!(role: "view")
    put "#{members_path}/#{other.key}", params: { role: "view" }, headers: auth_headers(member_user), as: :json
    expect(response).to have_http_status(:forbidden)
    put "#{members_path}/#{other.key}", params: { role: "owner" }, headers: auth_headers(owner_user), as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "404s a share the caller cannot see" do
    get members_path, headers: auth_headers(other_user)
    expect(response).to have_http_status(:not_found)
  end

  it "404s another org's share and another org's member" do
    outsider = create(:membership, organization: outsider_org)
    get disk_path("/shares/#{foreign_share.key}/members"), headers: auth_headers(owner_user)
    expect(response).to have_http_status(:not_found)
    put "#{members_path}/#{outsider.key}", params: { role: "view" }, headers: auth_headers(owner_user), as: :json
    expect(response).to have_http_status(:not_found)
    delete "#{members_path}/#{outsider.key}", headers: auth_headers(owner_user)
    expect(response).to have_http_status(:not_found)
  end
end
