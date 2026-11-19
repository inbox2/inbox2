require "rails_helper"

RSpec.describe "Api::V1::Mailboxes Graph", type: :request do
  # E1 mapping: Command Center mailbox graph — see docs/Explorer.md (no dedicated A-number)
  let(:owner) { create(:user, username: "graphowner") }
  let(:org) { create(:organization, owner: owner, domain: "graph.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  describe "GET /api/v1/orgs/:org_id/mailboxes/graph" do
    context "with a precomputed snapshot" do
      let!(:snapshot) do
        create(:mailbox_graph_snapshot,
          organization: org,
          payload: {
            nodes: [
              { id: "inbox@graph.com", address: "inbox@graph.com", name: "inbox", type: "mailbox", total: 5, unread: 2, urgency: 0.4 },
              { id: "alice@ext.com", address: "alice@ext.com", name: "Alice", type: "external", total: 3, mailbox_count: 1 }
            ],
            links: [
              { source: "alice@ext.com", target: "inbox@graph.com", weight: 3, kind: "inbound" }
            ]
          }.to_json,
          computed_at: 1.minute.ago,
          source_version: "abc123"
        )
      end

      it "returns the graph payload with 200" do
        get "/api/v1/orgs/#{org.key}/mailboxes/graph", headers: headers

        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        graph = body["graph"]
        expect(graph["nodes"]).to be_an(Array)
        expect(graph["nodes"].length).to eq(2)
        expect(graph["links"]).to be_an(Array)
        expect(graph["links"].length).to eq(1)
        expect(graph["computed_at"]).to be_present
        expect(graph["id"]).to start_with("mgs_")
      end

      it "does not expose internal numeric IDs in the response" do
        get "/api/v1/orgs/#{org.key}/mailboxes/graph", headers: headers

        body = response.parsed_body.to_json
        # The snapshot's internal numeric ID should never appear
        expect(body).not_to include("\"id\":#{snapshot.id}")
        # The organization's internal numeric ID should never appear
        expect(body).not_to include("\"organization_id\":#{org.id}")
      end
    end

    context "without a snapshot" do
      it "returns 202 Accepted and triggers computation" do
        expect {
          get "/api/v1/orgs/#{org.key}/mailboxes/graph", headers: headers
        }.to have_enqueued_job(RefreshMailboxGraphJob).with(org.id)

        expect(response).to have_http_status(:accepted)
        body = response.parsed_body
        expect(body["graph"]).to be_nil
        expect(body["status"]).to eq("computing")
      end
    end

    context "tenant isolation" do
      let(:other_owner) { create(:user, username: "otherownerx") }
      let(:other_org) { create(:organization, owner: other_owner, domain: "other-graph.com") }
      let!(:other_membership) { create(:membership, user: other_owner, organization: other_org, role: "owner", status: "active") }
      let!(:other_snapshot) do
        create(:mailbox_graph_snapshot,
          organization: other_org,
          payload: { nodes: [{ id: "secret@other-graph.com" }], links: [] }.to_json,
          computed_at: Time.current,
          source_version: "xyz"
        )
      end

      it "returns 404 when accessing another org's graph" do
        get "/api/v1/orgs/#{other_org.key}/mailboxes/graph", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end

    context "unauthenticated" do
      it "returns 401" do
        get "/api/v1/orgs/#{org.key}/mailboxes/graph"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with invalid org ID" do
      it "returns 404 for nonexistent org" do
        get "/api/v1/orgs/org_nonexistent/mailboxes/graph", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "GET /api/v1/orgs/:org_id/mailboxes/stats" do
    before do
      create(:conversation, organization: org, to_address: "inbox@graph.com", from_address: "a@b.com", read: false)
    end

    it "returns 202 and enqueues a refresh on cold start (no snapshot yet)" do
      expect {
        get "/api/v1/orgs/#{org.key}/mailboxes/stats", headers: headers
      }.to have_enqueued_job(RefreshMailboxGraphJob)

      expect(response).to have_http_status(:accepted)
      body = response.parsed_body
      expect(body["status"]).to eq("computing")
      expect(body["nodes"]).to eq([])
      expect(body["links"]).to eq([])
    end

    it "serves the precomputed snapshot when present" do
      create(:mailbox_graph_snapshot, organization: org,
        payload: { "nodes" => [{ "id" => "a@b.com" }], "links" => [], "stats" => { "inbound_today" => 3 } },
        computed_at: 1.minute.ago, source_version: "abc123")

      get "/api/v1/orgs/#{org.key}/mailboxes/stats", headers: headers

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["nodes"]).to be_an(Array)
      expect(body["links"]).to be_an(Array)
      expect(body["stats"]).to eq("inbound_today" => 3)
    end
  end

  describe "GET /api/v1/orgs/:org_id/mailboxes/pair" do
    before do
      c1 = create(:conversation, organization: org, to_address: "inbox@graph.com", from_address: "alice@ext.com",
        subject: "Invoice question", read: false, updated_at: 1.hour.ago)
      create(:conversation, organization: org, to_address: "inbox@graph.com", from_address: "alice@ext.com",
        subject: "Follow-up", read: true, updated_at: 2.days.ago)
      # Different pair — must not leak in
      create(:conversation, organization: org, to_address: "inbox@graph.com", from_address: "bob@ext.com",
        subject: "Unrelated", read: false)
      c1
    end

    it "returns counts, last activity and recent conversations for the pair" do
      get "/api/v1/orgs/#{org.key}/mailboxes/pair",
        params: { source: "alice@ext.com", target: "inbox@graph.com" }, headers: headers

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["total"]).to eq(2)
      expect(body["unread"]).to eq(1)
      expect(body["last_activity_at"]).to be_present
      subjects = body["conversations"].map { |c| c["subject"] }
      expect(subjects).to contain_exactly("Invoice question", "Follow-up")
      expect(body["conversations"].first["id"]).to start_with("conv_")
    end

    it "is direction-agnostic" do
      get "/api/v1/orgs/#{org.key}/mailboxes/pair",
        params: { source: "inbox@graph.com", target: "alice@ext.com" }, headers: headers

      expect(response.parsed_body["total"]).to eq(2)
    end

    it "returns 400 when source or target is missing" do
      get "/api/v1/orgs/#{org.key}/mailboxes/pair", params: { source: "alice@ext.com" }, headers: headers
      expect(response).to have_http_status(:bad_request)
    end

    it "returns 404 for another org's pair data" do
      other_owner = create(:user, username: "pairotherown")
      other_org = create(:organization, owner: other_owner, domain: "pair-other.com")
      create(:membership, user: other_owner, organization: other_org, role: "owner", status: "active")

      get "/api/v1/orgs/#{other_org.key}/mailboxes/pair",
        params: { source: "a@b.com", target: "c@d.com" }, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "returns 401 unauthenticated" do
      get "/api/v1/orgs/#{org.key}/mailboxes/pair", params: { source: "a@b.com", target: "c@d.com" }
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
