require "rails_helper"

RSpec.describe "Api::V1::AdminUsers", type: :request do
  let(:owner) { create(:user, username: "adminowner") }
  let(:org1) { create(:organization, owner: owner, domain: "alpha.com") }
  let(:org2) { create(:organization, owner: owner, domain: "beta.com") }
  let!(:o1) { create(:membership, user: owner, organization: org1, role: "owner", status: "active") }
  let!(:o2) { create(:membership, user: owner, organization: org2, role: "owner", status: "active") }
  # Serial tier so the collaborator cap (Free = 0 seats) doesn't gate the assign tests.
  let!(:sub1) { create(:subscription, organization: org1, plan: Plan.max) }
  let!(:sub2) { create(:subscription, organization: org2, plan: Plan.max) }
  let(:headers) { auth_headers(owner) }

  # A member who belongs to org1 (managed) and an unmanaged stranger org.
  let(:member) { create(:user, username: "worker") }
  let!(:member_m1) { create(:membership, user: member, organization: org1, role: "member", status: "active") }
  let!(:member_mbx) { create(:mailbox, membership: member_m1, domain: org1.default_domain, local_part: "worker") }
  let(:stranger_org) { create(:organization, owner: create(:user, username: "stranger"), domain: "elsewhere.com") }
  let!(:member_stranger) { create(:membership, user: member, organization: stranger_org, role: "member", status: "active") }

  describe "GET /api/v1/admin/users" do
    it "lists users across managed domains with only managed memberships (E3)" do
      get "/api/v1/admin/users", headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      users = response.parsed_body["users"]
      worker = users.find { |u| u["username"] == "worker" }
      expect(worker).to be_present
      domains = worker["memberships"].map { |m| m["organization"]["domain"] }
      expect(domains).to contain_exactly("alpha.com") # NOT elsewhere.com
    end

    it "is empty for a user who manages nothing" do
      nobody = create(:user, username: "nobody")
      get "/api/v1/admin/users", headers: auth_headers(nobody), as: :json
      expect(response.parsed_body["users"]).to eq([])
    end

    it "self-heals: an owner with no membership row still appears in their team list as owner" do
      # A legacy/seeded org owned by `loner` with NO owner membership row.
      loner = create(:user, username: "loner")
      org = create(:organization, owner: loner, domain: "loner.com")
      expect(org.memberships.where(user: loner)).to be_empty

      get "/api/v1/admin/users", headers: auth_headers(loner), as: :json
      expect(response).to have_http_status(:ok)

      me = response.parsed_body["users"].find { |u| u["username"] == "loner" }
      expect(me).to be_present, "the owner must appear in their own team list"
      m = me["memberships"].find { |x| x["organization"]["domain"] == "loner.com" }
      expect(m["role"]).to eq("owner")
      expect(m["status"]).to eq("active")
      # The heal persisted a real membership so all membership-based logic agrees.
      expect(org.reload.memberships.find_by(user: loner)&.role).to eq("owner")
    end
  end

  describe "POST /api/v1/admin/users/:user_id/assign" do
    let(:outsider) { create(:user, username: "outsider") }

    it "assigns a user to a managed domain as an invited membership" do
      post "/api/v1/admin/users/#{outsider.key}/assign",
        params: { org_id: org2.key, role: "member" }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["member"]["status"]).to eq("invited")
      expect(org2.memberships.find_by(user: outsider).role).to eq("member")
    end

    it "forbids assigning to an unmanaged domain" do
      post "/api/v1/admin/users/#{outsider.key}/assign",
        params: { org_id: stranger_org.key }, headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "rejects a duplicate domain assignment" do
      post "/api/v1/admin/users/#{member.key}/assign",
        params: { org_id: org1.key }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_content)
    end

    it "enforces the grant ceiling (admin cannot grant admin)" do
      admin = create(:user, username: "adm")
      create(:membership, user: admin, organization: org1, role: "admin", status: "active")
      post "/api/v1/admin/users/#{outsider.key}/assign",
        params: { org_id: org1.key, role: "admin" }, headers: auth_headers(admin), as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "DELETE /api/v1/admin/users/:user_id/assign" do
    it "removes a single membership (per-domain disconnect)" do
      expect {
        delete "/api/v1/admin/users/#{member.key}/assign", params: { org_id: org1.key }, headers: headers, as: :json
      }.to change { org1.memberships.where(user: member).count }.from(1).to(0)
      expect(response).to have_http_status(:no_content)
      expect(stranger_org.memberships.where(user: member)).to exist # untouched
    end

    it "refuses to remove yourself" do
      delete "/api/v1/admin/users/#{owner.key}/assign", params: { org_id: org1.key }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_content)
    end

    it "does NOT revoke the user's sessions (gentle disconnect — no forced re-login)" do
      member.sessions.create!(ip_address: "1.1.1.1", user_agent: "x", last_active_at: Time.current)
      delete "/api/v1/admin/users/#{member.key}/assign", params: { org_id: org1.key }, headers: headers, as: :json
      expect(response).to have_http_status(:no_content)
      expect(member.sessions.count).to eq(1) # still signed in for their other domains
    end
  end

  describe "PATCH /api/v1/admin/users/:user_id/status" do
    it "disables across all managed domains only and revokes sessions" do
      member.sessions.create!(ip_address: "1.1.1.1", user_agent: "x", last_active_at: Time.current)
      patch "/api/v1/admin/users/#{member.key}/status",
        params: { status: "disabled", scope: "all" }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(org1.memberships.find_by(user: member).status).to eq("disabled")
      expect(stranger_org.memberships.find_by(user: member).status).to eq("active") # E3
      expect(member.sessions.count).to eq(0)
    end

    it "re-enables a membership in one domain" do
      member_m1.update!(status: "disabled")
      patch "/api/v1/admin/users/#{member.key}/status",
        params: { status: "active", scope: "membership", org_id: org1.key }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(member_m1.reload.status).to eq("active")
    end

    it "refuses to re-enable a membership when the plan has no free seat" do
      member_m1.update!(status: "disabled")
      sub1.update!(plan: Plan.free) # 0 seats
      patch "/api/v1/admin/users/#{member.key}/status",
        params: { status: "active", scope: "membership", org_id: org1.key }, headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(member_m1.reload.status).to eq("disabled")
    end

    it "rejects an invalid status" do
      patch "/api/v1/admin/users/#{member.key}/status",
        params: { status: "invited", scope: "all" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_content)
    end

    it "refuses to disable yourself" do
      patch "/api/v1/admin/users/#{owner.key}/status",
        params: { status: "disabled", scope: "all" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /api/v1/admin/users/:user_id (offboard)" do
    it "global delete removes managed memberships but leaves unmanaged ones (E3)" do
      delete "/api/v1/admin/users/#{member.key}", params: { data_handling: "archive", alias_handling: "bounce" },
        headers: headers, as: :json
      expect(response).to have_http_status(:no_content)
      expect(org1.memberships.where(user: member)).not_to exist
      expect(stranger_org.memberships.where(user: member)).to exist
      expect(org1.mailbox_aliases.find_by(local_part: "worker").mode).to eq("bounce")
    end

    it "wipe deletes the departed mailbox's mail but keeps shared threads" do
      shared = create(:conversation, organization: org1)
      create(:message, conversation: shared, organization: org1, to_address: "worker@alpha.com", from_address: "ext@x.com")
      create(:message, conversation: shared, organization: org1, to_address: "someone-else@alpha.com", from_address: "ext@x.com")
      solo = create(:conversation, organization: org1)
      create(:message, conversation: solo, organization: org1, from_address: "worker@alpha.com", to_address: "ext@x.com")

      delete "/api/v1/admin/users/#{member.key}", params: { scope: "global", data_handling: "wipe", alias_handling: "bounce" },
        headers: headers, as: :json
      expect(response).to have_http_status(:no_content)
      expect(Conversation.exists?(solo.id)).to be false           # emptied → removed
      expect(Conversation.exists?(shared.id)).to be true          # still has others' mail
      expect(shared.messages.pluck(:to_address)).to contain_exactly("someone-else@alpha.com")
    end

    it "reroute requires a valid active target" do
      delete "/api/v1/admin/users/#{member.key}",
        params: { scope: "domain", org_id: org1.key, alias_handling: "reroute", reroute_target_id: "mbr_missing" },
        headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_content)
      expect(org1.memberships.where(user: member)).to exist # rolled back
    end

    it "reroute grants the chosen member the retired mailbox" do
      delete "/api/v1/admin/users/#{member.key}",
        params: { scope: "domain", org_id: org1.key, alias_handling: "reroute", reroute_target_id: o1.key },
        headers: headers, as: :json
      expect(response).to have_http_status(:no_content)
      alias_row = org1.mailbox_aliases.find_by(local_part: "worker")
      expect(alias_row.mode).to eq("reroute")
      expect(alias_row.target_membership).to eq(o1)
    end
  end
end
