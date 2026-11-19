require "rails_helper"

RSpec.describe "Api::V1::Mcp", type: :request do
  let(:owner) { create(:user, username: "mcpowner") }
  let(:org) { create(:organization, owner: owner, domain: "mcp.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:agent) { create(:agent, organization: org, membership: membership) }
  let(:token) { agent.generate_credential! }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }

  describe "authentication" do
    it "rejects requests without an agent credential" do
      get "/api/v1/orgs/#{org.key}/mcp/tools"
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a human session/API token (agent credential required)" do
      get "/api/v1/orgs/#{org.key}/mcp/tools", headers: auth_headers(owner)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /api/v1/orgs/:org_id/mcp/tools (spec 14.3, A17.3)" do
    it "lists tools the agent is permitted to use" do
      get "/api/v1/orgs/#{org.key}/mcp/tools", headers: headers
      expect(response).to have_http_status(:ok)
      tools = response.parsed_body["tools"]
      expect(tools.length).to eq(6)
      expect(tools.map { |t| t["name"] }).to include("list_conversations", "search", "reply")
    end

    it "hides tools the agent lacks permission for" do
      agent.update!(permissions: [Agent::PERMISSIONS.first]) # read only
      get "/api/v1/orgs/#{org.key}/mcp/tools", headers: headers
      names = response.parsed_body["tools"].map { |t| t["name"] }
      expect(names).to include("list_conversations")
      expect(names).not_to include("reply", "set_status")
    end
  end

  describe "POST /api/v1/orgs/:org_id/mcp/execute" do
    it "executes list_conversations tool" do
      create(:conversation, organization: org, subject: "MCP Test")
      post "/api/v1/orgs/#{org.key}/mcp/execute",
           params: { tool: "list_conversations", params: { limit: 5 } },
           headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["result"].first["subject"]).to eq("MCP Test")
    end

    it "executes get_conversation tool" do
      conv = create(:conversation, organization: org, subject: "Detail Test")
      create(:message, conversation: conv, organization: org, from_address: "sender@test.com")

      post "/api/v1/orgs/#{org.key}/mcp/execute",
           params: { tool: "get_conversation", params: { conversation_id: conv.key } },
           headers: headers
      expect(response).to have_http_status(:ok)
      result = response.parsed_body["result"]
      expect(result["subject"]).to eq("Detail Test")
      expect(result["messages"].length).to eq(1)
    end

    it "executes add_tag tool" do
      conv = create(:conversation, organization: org)
      create(:tag, organization: org, name: "priority")

      post "/api/v1/orgs/#{org.key}/mcp/execute",
           params: { tool: "add_tag", params: { conversation_id: conv.key, tag: "priority" } },
           headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["result"]["tags"]).to include("priority")
    end

    it "executes set_status tool" do
      conv = create(:conversation, organization: org, status: Conversation::STATUS_OPEN)

      post "/api/v1/orgs/#{org.key}/mcp/execute",
           params: { tool: "set_status", params: { conversation_id: conv.key, status: Conversation::STATUS_ARCHIVED } },
           headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["result"]["status"]).to eq(Conversation::STATUS_ARCHIVED)
    end

    it "denies a tool the agent has no permission for" do
      agent.update!(permissions: ["read"])
      conv = create(:conversation, organization: org, status: Conversation::STATUS_OPEN)

      post "/api/v1/orgs/#{org.key}/mcp/execute",
           params: { tool: "set_status", params: { conversation_id: conv.key, status: Conversation::STATUS_ARCHIVED } },
           headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(conv.reload.status).to eq(Conversation::STATUS_OPEN)
    end

    it "records every call in the agent run log (audit)" do
      create(:conversation, organization: org)
      expect do
        post "/api/v1/orgs/#{org.key}/mcp/execute",
             params: { tool: "list_conversations" }, headers: headers
      end.to change { agent.run_logs.count }.by(1)
    end

    it "parks a reply as a draft when approval is required" do
      agent.update!(approval_required: true)
      conv = create(:conversation, organization: org, from_address: "ext@test.com")

      post "/api/v1/orgs/#{org.key}/mcp/execute",
           params: { tool: "reply", params: { conversation_id: conv.key, body: "hi" } },
           headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["result"]["status"]).to eq("pending_approval")
      expect(conv.messages.last).to be_is_draft
    end

    it "rejects unknown tool" do
      post "/api/v1/orgs/#{org.key}/mcp/execute",
           params: { tool: "nonexistent" },
           headers: headers
      expect(response).to have_http_status(:bad_request)
    end
  end
end
