require "rails_helper"

RSpec.describe "Api::V1::Rules preview + backfill", type: :request do
  let(:owner) { create(:user, username: "rulepbowner") }
  let(:org) { create(:organization, owner: owner, domain: "rulepb.com") }
  let!(:owner_membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:headers) { auth_headers(owner) }

  # Preview matches for an unsaved rule (the create-wizard review step).
  describe "POST /api/v1/orgs/:org_id/rules/preview" do
    it "counts existing conversations matching inline conditions" do
      conv = create(:conversation, organization: org, subject: "Security alert")
      create(:message, conversation: conv, organization: org,
                       from_address: "security@facebookmail.com", to_address: "khuram@rulepb.com")

      post "/api/v1/orgs/#{org.key}/rules/preview",
           params: { conditions: [
             { field: "from", operator: "contains", value: "facebook" },
             { field: "to", operator: "contains", value: "khuram@rulepb.com" }
           ] },
           headers: headers

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["total"]).to eq(1)
      expect(body["samples"].length).to eq(1)
      expect(body["scanned_capped"]).to be(false)
    end

    it "returns zero when nothing matches" do
      create(:message, conversation: create(:conversation, organization: org), organization: org, from_address: "a@b.com")

      post "/api/v1/orgs/#{org.key}/rules/preview",
           params: { conditions: [{ field: "from", operator: "contains", value: "nomatch" }] },
           headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["total"]).to eq(0)
    end

    it "returns zero for empty conditions (never matches everything)" do
      post "/api/v1/orgs/#{org.key}/rules/preview", params: { conditions: [] }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["total"]).to eq(0)
    end

    it "forbids non-admins" do
      member = create(:user, username: "rulepbmember")
      create(:membership, user: member, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)

      post "/api/v1/orgs/#{org.key}/rules/preview",
           params: { conditions: [{ field: "from", operator: "contains", value: "x" }] },
           headers: auth_headers(member)

      expect(response).to have_http_status(:forbidden)
    end

    # E3 tenant isolation — another org's mail is never scanned.
    it "does not match another org's conversations" do
      other_owner = create(:user, username: "rulepbother")
      other_org = create(:organization, owner: other_owner, domain: "rulepbother.com")
      create(:membership, user: other_owner, organization: other_org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE)
      oc = create(:conversation, organization: other_org)
      create(:message, conversation: oc, organization: other_org, from_address: "security@facebookmail.com")

      post "/api/v1/orgs/#{org.key}/rules/preview",
           params: { conditions: [{ field: "from", operator: "contains", value: "facebook" }] },
           headers: headers

      expect(response.parsed_body["total"]).to eq(0)
    end
  end

  describe "POST /api/v1/orgs/:org_id/rules/:id/apply-existing" do
    it "enqueues the backfill job" do
      rule = create(:rule, organization: org)
      expect(RuleBackfillJob).to receive(:perform_later).with(rule.id)

      post "/api/v1/orgs/#{org.key}/rules/#{rule.key}/apply-existing", headers: headers

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body["enqueued"]).to be(true)
    end

    it "forbids non-admins" do
      member = create(:user, username: "rulepbmember2")
      create(:membership, user: member, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)
      rule = create(:rule, organization: org)

      post "/api/v1/orgs/#{org.key}/rules/#{rule.key}/apply-existing", headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
    end

    it "404s an unknown rule" do
      post "/api/v1/orgs/#{org.key}/rules/rule_nope/apply-existing", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
