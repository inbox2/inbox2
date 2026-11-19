require "rails_helper"

RSpec.describe "Api::V1::Agents", type: :request do
  # E1 mapping: spec 5.5.1-5.5.9, A5.1-A5.9 — AI agents
  let(:owner) { create(:user, username: "agtowner") }
  let(:org) { create(:organization, owner: owner, domain: "agents.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  describe "POST /api/v1/orgs/:org_id/agents" do
    it "creates an agentic user" do
      expect {
        post "/api/v1/orgs/#{org.key}/agents",
             params: { name: "Support Bot", permissions: ["read", "reply"], approval_required: true },
             headers: headers
      }.to change(Agent, :count).by(1)

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["agent"]["name"]).to eq("Support Bot")
      expect(body["agent"]["id"]).to start_with("agt_")
      expect(body["agent"]["approval_required"]).to eq(true)
      expect(body["agent"]["permissions"]).to eq(["read", "reply"])
    end
  end

  describe "GET /api/v1/orgs/:org_id/agents" do
    it "lists agents" do
      agent_user = create(:user, username: "bot1")
      agent_membership = create(:membership, user: agent_user, organization: org, role: "member", status: "active", member_type: "agent")
      Agent.create!(organization: org, membership: agent_membership, name: "Bot 1")

      get "/api/v1/orgs/#{org.key}/agents", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["agents"].length).to eq(1)
    end
  end

  describe "POST /api/v1/orgs/:org_id/agents/:id/credentials" do
    it "generates API credentials" do
      agent_user = create(:user, username: "credbot")
      agent_membership = create(:membership, user: agent_user, organization: org, role: "member", status: "active", member_type: "agent")
      agent = Agent.create!(organization: org, membership: agent_membership, name: "Cred Bot")

      post "/api/v1/orgs/#{org.key}/agents/#{agent.key}/credentials", headers: headers
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["token"]).to start_with("agt_")
    end
  end

  describe "GET /api/v1/orgs/:org_id/agents/:id/feed" do
    it "returns conversations assigned to the agent" do
      agent_user = create(:user, username: "feedbot")
      agent_membership = create(:membership, user: agent_user, organization: org, role: "member", status: "active", member_type: "agent")
      agent = Agent.create!(organization: org, membership: agent_membership, name: "Feed Bot")

      conv = create(:conversation, organization: org)
      conv.assignees << agent_membership

      get "/api/v1/orgs/#{org.key}/agents/#{agent.key}/feed", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["conversations"].length).to eq(1)
    end

    it "forbids regular members (admin-only, like the rest of agent management)" do
      agent = make_agent("Feed Guard")
      member = create(:user, username: "feedmember")
      create(:membership, user: member, organization: org, role: "member", status: "active")
      get "/api/v1/orgs/#{org.key}/agents/#{agent.key}/feed", headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/orgs/:org_id/agents/approval-queue" do
    it "forbids regular members" do
      member = create(:user, username: "aqmember")
      create(:membership, user: member, organization: org, role: "member", status: "active")
      get "/api/v1/orgs/#{org.key}/agents/approval-queue", headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "tenant isolation (E3)" do
    it "returns 404 for agents in another org" do
      other_user = create(:user, username: "agtiso")
      other_org = create(:organization, owner: other_user, domain: "agtiso.com")
      create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")

      get "/api/v1/orgs/#{other_org.key}/agents", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  # Helper: build an agent (agent-typed membership + Agent record) in `org`
  def make_agent(name)
    u = create(:user, username: "bot_#{SecureRandom.hex(4)}")
    m = create(:membership, user: u, organization: org, role: "member", status: "active", member_type: "agent")
    Agent.create!(organization: org, membership: m, name: name)
  end

  describe "GET /api/v1/orgs/:org_id/agents/:id" do
    context "positive" do
      it "returns an agent" do
        agent = make_agent("Show Bot")
        get "/api/v1/orgs/#{org.key}/agents/#{agent.key}", headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["agent"]["name"]).to eq("Show Bot")
      end
    end

    context "negative" do
      it "returns 404 for an unknown agent" do
        get "/api/v1/orgs/#{org.key}/agents/agt_missing", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "PATCH /api/v1/orgs/:org_id/agents/:id" do
    context "positive" do
      it "updates an agent (admin)" do
        agent = make_agent("Upd Bot")
        patch "/api/v1/orgs/#{org.key}/agents/#{agent.key}", params: { name: "Renamed" }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["agent"]["name"]).to eq("Renamed")
      end
    end

    context "negative" do
      it "returns 422 for an invalid status" do
        agent = make_agent("Bad Status Bot")
        patch "/api/v1/orgs/#{org.key}/agents/#{agent.key}", params: { status: "bogus" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "forbids regular members" do
        agent = make_agent("Guarded Bot")
        member = create(:user, username: "agtmember")
        create(:membership, user: member, organization: org, role: "member", status: "active")
        patch "/api/v1/orgs/#{org.key}/agents/#{agent.key}", params: { name: "X" }, headers: auth_headers(member)
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "DELETE /api/v1/orgs/:org_id/agents/:id" do
    context "positive" do
      it "deletes an agent (admin)" do
        agent = make_agent("Del Bot")
        expect {
          delete "/api/v1/orgs/#{org.key}/agents/#{agent.key}", headers: headers
        }.to change(Agent, :count).by(-1)
        expect(response).to have_http_status(:no_content)
      end
    end

    context "negative" do
      it "returns 404 for an unknown agent" do
        delete "/api/v1/orgs/#{org.key}/agents/agt_missing", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "GET /api/v1/orgs/:org_id/agents/:id/run-logs" do
    context "positive" do
      it "returns run logs with rate/spend flags (admin)" do
        agent = make_agent("Log Bot")
        agent.run_logs.create!(action: "reply", status: AgentRunLog::STATUS_SUCCESS)

        get "/api/v1/orgs/#{org.key}/agents/#{agent.key}/run-logs", headers: headers
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["run_logs"].length).to eq(1)
        expect(body).to have_key("rate_limited")
        expect(body).to have_key("spend_limited")
      end
    end

    context "negative" do
      it "forbids regular members" do
        agent = make_agent("Log Bot 2")
        member = create(:user, username: "agtmember2")
        create(:membership, user: member, organization: org, role: "member", status: "active")
        get "/api/v1/orgs/#{org.key}/agents/#{agent.key}/run-logs", headers: auth_headers(member)
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "GET /api/v1/orgs/:org_id/agents/approval-queue" do
    it "lists draft messages awaiting approval for agent-assigned conversations" do
      agent = make_agent("Queue Bot")
      conv = create(:conversation, organization: org)
      conv.assignees << agent.membership
      create(:message, conversation: conv, organization: org, is_draft: true, owner_membership_id: agent.membership_id)
      # A person's own draft on the same agent-assigned thread stays theirs.
      create(:message, conversation: conv, organization: org, is_draft: true, owner_membership_id: membership.id)

      get "/api/v1/orgs/#{org.key}/agents/approval-queue", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["pending_approvals"].length).to eq(1)
    end
  end
end
