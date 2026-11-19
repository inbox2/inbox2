require "rails_helper"

RSpec.describe "Api::V1::Rules", type: :request do
  let(:owner) { create(:user, username: "ruleowner") }
  let(:org) { create(:organization, owner: owner, domain: "rules.com") }
  let!(:owner_membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:headers) { auth_headers(owner) }

  # --- Spec 7.1.1, A11.1 — List rules ---
  describe "GET /api/v1/orgs/:org_id/rules" do
    it "lists rules ordered by position" do
      create(:rule, organization: org, name: "Second", position: 1)
      create(:rule, organization: org, name: "First", position: 0)

      get "/api/v1/orgs/#{org.key}/rules", headers: headers
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["rules"].length).to eq(2)
      expect(body["rules"].first["name"]).to eq("First")
      body["rules"].each { |r| expect(r["id"]).to start_with("rule_") }
    end
  end

  # --- Create rule ---
  describe "POST /api/v1/orgs/:org_id/rules" do
    it "creates a rule" do
      post "/api/v1/orgs/#{org.key}/rules",
           params: {
             name: "Sales routing",
             conditions: [{ field: "to", operator: "equals", value: "sales@" }],
             actions: [{ type: "assign", value: "usr_abc" }]
           },
           headers: headers
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["rule"]["name"]).to eq("Sales routing")
      expect(response.parsed_body["rule"]["enabled"]).to eq(true)
    end

    # spec 7.3.12 — Conditional branching
    it "creates a rule with branches and else_actions" do
      post "/api/v1/orgs/#{org.key}/rules",
           params: {
             name: "Branching rule",
             conditions: [{ field: "from", operator: "contains", value: "vip" }],
             actions: [{ type: "set_status", value: Conversation::STATUS_PENDING }],
             branches: [
               { conditions: [{ field: "subject", operator: "contains", value: "urgent" }],
                 actions: [{ type: "set_status", value: Conversation::STATUS_OPEN }] }
             ],
             else_actions: [{ type: "set_status", value: Conversation::STATUS_ARCHIVED }]
           },
           headers: headers
      expect(response).to have_http_status(:created)
      rule = response.parsed_body["rule"]
      expect(rule["branches"]).to be_present
      expect(rule["else_actions"]).to be_present
    end

    it "forbids regular members" do
      member = create(:user, username: "rulemember")
      create(:membership, user: member, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)

      post "/api/v1/orgs/#{org.key}/rules",
           params: { name: "Blocked", conditions: [{}], actions: [{}] },
           headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
    end
  end

  # --- Update rule ---
  describe "PATCH /api/v1/orgs/:org_id/rules/:id" do
    let!(:rule) { create(:rule, organization: org, name: "Original") }

    it "updates a rule" do
      patch "/api/v1/orgs/#{org.key}/rules/#{rule.key}",
            params: { name: "Updated" },
            headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["rule"]["name"]).to eq("Updated")
    end

    it "returns 404 for tenant isolation (E3)" do
      other_user = create(:user, username: "ruleiso")
      other_org = create(:organization, owner: other_user, domain: "ruleiso.com")
      create(:membership, user: other_user, organization: other_org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE)
      other_rule = create(:rule, organization: other_org)

      patch "/api/v1/orgs/#{org.key}/rules/#{other_rule.key}",
            params: { name: "Stolen" },
            headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  # --- Delete rule ---
  describe "DELETE /api/v1/orgs/:org_id/rules/:id" do
    let!(:rule) { create(:rule, organization: org) }

    it "deletes a rule" do
      expect {
        delete "/api/v1/orgs/#{org.key}/rules/#{rule.key}", headers: headers
      }.to change(Rule, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end
  end

  # --- Spec A11.2 — Reorder ---
  describe "PUT /api/v1/orgs/:org_id/rules/order" do
    let!(:rule1) { create(:rule, organization: org, name: "A", position: 0) }
    let!(:rule2) { create(:rule, organization: org, name: "B", position: 1) }

    it "reorders rules" do
      put "/api/v1/orgs/#{org.key}/rules/order",
          params: { rule_ids: [rule2.key, rule1.key] },
          headers: headers
      expect(response).to have_http_status(:ok)
      expect(rule2.reload.position).to eq(0)
      expect(rule1.reload.position).to eq(1)
    end
  end

  # --- Spec A11.3 — Toggle ---
  describe "PATCH /api/v1/orgs/:org_id/rules/:id/toggle" do
    let!(:rule) { create(:rule, organization: org, enabled: true) }

    it "toggles a rule on/off" do
      patch "/api/v1/orgs/#{org.key}/rules/#{rule.key}/toggle", headers: headers
      expect(response).to have_http_status(:ok)
      expect(rule.reload.enabled).to eq(false)

      patch "/api/v1/orgs/#{org.key}/rules/#{rule.key}/toggle", headers: headers
      expect(rule.reload.enabled).to eq(true)
    end
  end

  # --- rules#run_log — execution history for a rule ---
  describe "GET /api/v1/orgs/:org_id/rules/:id/run-log" do
    context "positive" do
      it "returns the rule's recent run log entries (admin)" do
        rule = create(:rule, organization: org)
        conv = create(:conversation, organization: org)
        rule.rule_logs.create!(conversation: conv, result: "matched")

        get "/api/v1/orgs/#{org.key}/rules/#{rule.key}/run-log", headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["run_log"].length).to eq(1)
      end
    end

    context "negative" do
      it "forbids regular members" do
        rule = create(:rule, organization: org)
        member = create(:user, username: "rulemember")
        create(:membership, user: member, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)
        get "/api/v1/orgs/#{org.key}/rules/#{rule.key}/run-log", headers: auth_headers(member)
        expect(response).to have_http_status(:forbidden)
      end

      it "returns 404 for an unknown rule" do
        get "/api/v1/orgs/#{org.key}/rules/rule_missing/run-log", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # --- rules#dry_run — preview which conversations a rule would match ---
  describe "POST /api/v1/orgs/:org_id/rules/:id/dry-run" do
    context "positive" do
      it "returns matching conversations and a count (admin)" do
        rule = create(:rule, organization: org,
                       conditions: [{ "field" => "from", "operator" => "contains", "value" => "match" }])
        hit = create(:conversation, organization: org)
        create(:message, conversation: hit, organization: org, from_address: "match@x.com")
        miss = create(:conversation, organization: org)
        create(:message, conversation: miss, organization: org, from_address: "nope@x.com")

        post "/api/v1/orgs/#{org.key}/rules/#{rule.key}/dry-run", headers: headers
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["count"]).to eq(1)
        expect(body["matches"].length).to eq(1)
      end
    end

    context "negative" do
      it "forbids regular members" do
        rule = create(:rule, organization: org)
        member = create(:user, username: "rulemember2")
        create(:membership, user: member, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)
        post "/api/v1/orgs/#{org.key}/rules/#{rule.key}/dry-run", headers: auth_headers(member)
        expect(response).to have_http_status(:forbidden)
      end

      it "returns 404 for an unknown rule" do
        post "/api/v1/orgs/#{org.key}/rules/rule_missing/dry-run", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
