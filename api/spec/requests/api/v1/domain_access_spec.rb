require "rails_helper"

# Per-domain pool access: an org owns many equal domains sharing one pool, but a
# member may be scoped to specific domains and then sees only those domains'
# conversations — unless a thread is directly assigned/granted to them.
RSpec.describe "Domain-scoped pool access", type: :request do
  let(:owner) { create(:user, username: "da_owner") }
  let(:org) { create(:organization, owner: owner, domain: "alpha.test") }
  let!(:owner_m) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:domain_a) { org.default_domain } # alpha.test (oldest)
  let!(:domain_b) { create(:domain, organization: org, name: "beta.test") }

  # A regular member scoped to domain A only.
  let(:member_user) { create(:user, username: "da_member") }
  let!(:member_m) do
    create(:membership, user: member_user, organization: org, role: "member", status: "active")
      .tap { |m| m.update!(all_domains: false, domains: [domain_a]) }
  end

  let!(:conv_a) { create(:conversation, organization: org, domain: domain_a, subject: "alpha thread") }
  let!(:conv_b) { create(:conversation, organization: org, domain: domain_b, subject: "beta thread") }

  describe "conversation visibility" do
    it "a scoped member sees only their granted domain's conversations" do
      get "/api/v1/orgs/#{org.key}/conversations", headers: auth_headers(member_user)
      expect(response).to have_http_status(:ok)
      subjects = response.parsed_body["conversations"].map { |c| c["subject"] }
      expect(subjects).to contain_exactly("alpha thread")
    end

    it "an owner/admin sees every domain's conversations" do
      get "/api/v1/orgs/#{org.key}/conversations", headers: auth_headers(owner)
      subjects = response.parsed_body["conversations"].map { |c| c["subject"] }
      expect(subjects).to contain_exactly("alpha thread", "beta thread")
    end

    it "a scoped member 404s opening a conversation outside their domains" do
      get "/api/v1/orgs/#{org.key}/conversations/#{conv_b.key}", headers: auth_headers(member_user)
      expect(response).to have_http_status(:not_found)
    end

    it "a direct assignment overrides domain scoping (one-off cross-domain work)" do
      conv_b.assignees << member_m
      get "/api/v1/orgs/#{org.key}/conversations/#{conv_b.key}", headers: auth_headers(member_user)
      expect(response).to have_http_status(:ok)

      get "/api/v1/orgs/#{org.key}/conversations", headers: auth_headers(member_user)
      subjects = response.parsed_body["conversations"].map { |c| c["subject"] }
      expect(subjects).to contain_exactly("alpha thread", "beta thread")
    end

    it "a direct access grant also overrides domain scoping" do
      conv_b.accessible_members << member_m
      get "/api/v1/orgs/#{org.key}/conversations/#{conv_b.key}", headers: auth_headers(member_user)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "PATCH /members/:id domain access" do
    it "scopes a member to specific domains" do
      patch "/api/v1/orgs/#{org.key}/members/#{member_m.key}",
        params: { all_domains: false, domain_ids: [domain_b.key] }, headers: auth_headers(owner)
      expect(response).to have_http_status(:ok)
      body = response.parsed_body["member"]
      expect(body["all_domains"]).to be(false)
      expect(body["domains"].map { |d| d["name"] }).to contain_exactly("beta.test")
    end

    it "grants a member access to all domains (clears the scoping)" do
      patch "/api/v1/orgs/#{org.key}/members/#{member_m.key}",
        params: { all_domains: true }, headers: auth_headers(owner)
      expect(response.parsed_body["member"]["all_domains"]).to be(true)
      expect(member_m.reload.all_domains).to be(true)
      expect(member_m.domains).to be_empty
    end

    it "scopes an active member to zero domains — a limited member (spec 5.1.6)" do
      patch "/api/v1/orgs/#{org.key}/members/#{member_m.key}",
        params: { all_domains: false, domain_ids: [] }, headers: auth_headers(owner)
      expect(response).to have_http_status(:ok)
      body = response.parsed_body["member"]
      expect(body["all_domains"]).to be(false)
      expect(body["domains"]).to be_empty

      # They now see nothing except shared/rule-granted threads.
      get "/api/v1/orgs/#{org.key}/conversations", headers: auth_headers(member_user)
      expect(response.parsed_body["conversations"]).to be_empty
      conv_b.accessible_members << member_m.reload
      get "/api/v1/orgs/#{org.key}/conversations", headers: auth_headers(member_user)
      expect(response.parsed_body["conversations"].map { |c| c["subject"] }).to contain_exactly("beta thread")
    end

    it "reports owners as all_domains regardless of grants" do
      get "/api/v1/orgs/#{org.key}/members", headers: auth_headers(owner)
      owner_row = response.parsed_body["members"].find { |m| m["role"] == "owner" }
      expect(owner_row["all_domains"]).to be(true)
    end

    it "cannot grant a domain from another org (tenant isolation)" do
      other = create(:organization, domain: "evil.test")
      patch "/api/v1/orgs/#{org.key}/members/#{member_m.key}",
        params: { all_domains: false, domain_ids: [other.default_domain.key] }, headers: auth_headers(owner)
      # unknown-in-org key resolves to no domains → the foreign grant never lands
      expect(response).to have_http_status(:ok)
      expect(member_m.reload.domains).to be_empty
    end
  end

  describe "GET /admin/overview?domain=" do
    it "narrows pool stats to a single domain" do
      get "/api/v1/orgs/#{org.key}/admin/overview?domain=#{domain_b.key}", headers: auth_headers(owner)
      expect(response.parsed_body["overview"]["pool"]["volume"]).to eq(1)

      get "/api/v1/orgs/#{org.key}/admin/overview", headers: auth_headers(owner)
      expect(response.parsed_body["overview"]["pool"]["volume"]).to eq(2)
    end
  end
end
