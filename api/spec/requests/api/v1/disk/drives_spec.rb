require "rails_helper"

RSpec.describe "Api::V1::Disk::Drives", type: :request do
  include_context "disk org"

  describe "GET /disk" do
    it "returns my C:\\ root, the shares I can see and the quota" do
      open = make_share("Everyone", openness: "org")
      closed = make_share("Finance")
      Disk::ShareMembership.create!(organization: org, share: closed, membership: other, role: "view")

      get disk_path, headers: auth_headers(member_user)
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["c_drive"]["id"]).to start_with("dnd_")
      expect(body["c_drive"]["drive"]).to eq("C")
      expect(body["shares"].map { |s| s["id"] }).to eq([open.key])
      expect(body["quota"]).to include("pool_bytes" => 30.gigabytes, "used_bytes" => 0, "reserved_bytes" => 0)
      expect(body["settings"]["sealing_enabled"]).to eq(org.e2ee_entitled?)
    end

    it "creates the C:\\ root once" do
      2.times { get disk_path, headers: auth_headers(member_user) }
      expect(Disk::Node.where(custodian_membership_id: member.personal_membership_id, parent_id: nil).count).to eq(1)
    end

    it "401s without auth" do
      get disk_path
      expect(response).to have_http_status(:unauthorized)
    end

    it "404s for another org" do
      get "/api/v1/orgs/#{outsider_org.key}/disk", headers: auth_headers(member_user)
      expect(response).to have_http_status(:not_found)
    end
  end
end
