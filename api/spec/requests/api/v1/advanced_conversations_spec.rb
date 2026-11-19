require "rails_helper"

RSpec.describe "Api::V1::Conversations (advanced)", type: :request do
  # E1 mapping: spec 4.2.7/4.1.x, A6.1/A6.6 — Conversations: snooze, merge, split, pagination
  let(:owner) { create(:user, username: "advconv") }
  let(:org) { create(:organization, owner: owner, domain: "advconv.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  describe "POST /conversations/:id/snooze" do
    let!(:conv) { create(:conversation, organization: org, status: "open") }

    it "snoozes a conversation" do
      post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/snooze",
           params: { until: 2.days.from_now.iso8601 }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(conv.reload.status).to eq("pending")
      expect(conv.snoozed_until).to be_present
    end
  end

  describe "DELETE /conversations/:id/snooze" do
    let!(:conv) { create(:conversation, organization: org, status: "pending", snoozed_until: 1.day.from_now) }

    it "unsnoozes a conversation" do
      delete "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/snooze", headers: headers
      expect(response).to have_http_status(:ok)
      expect(conv.reload.status).to eq("open")
      expect(conv.snoozed_until).to be_nil
    end
  end

  describe "POST /conversations/:id/merge" do
    let!(:conv1) { create(:conversation, organization: org, subject: "Source") }
    let!(:conv2) { create(:conversation, organization: org, subject: "Target") }
    let!(:msg) { create(:message, conversation: conv1, organization: org) }

    it "merges conversations" do
      post "/api/v1/orgs/#{org.key}/conversations/#{conv1.key}/merge",
           params: { target_id: conv2.key }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(msg.reload.conversation).to eq(conv2)
      expect(Conversation.find_by(key: conv1.key)).to be_nil
    end
  end

  describe "POST /conversations/:id/split" do
    let!(:conv) { create(:conversation, organization: org, subject: "Original") }
    let!(:msg) { create(:message, conversation: conv, organization: org, subject: "Split me") }

    it "splits a message into a new conversation" do
      expect {
        post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/split",
             params: { message_id: msg.key }, headers: headers
      }.to change(Conversation, :count).by(1)
      expect(response).to have_http_status(:created)
      expect(msg.reload.conversation).not_to eq(conv)
    end
  end

  describe "pagination" do
    before { 30.times { |i| create(:conversation, organization: org, subject: "Conv #{i}") } }

    it "paginates conversations" do
      get "/api/v1/orgs/#{org.key}/conversations", params: { page: 2, per_page: 10 }, headers: headers
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["conversations"].length).to eq(10)
      expect(body["meta"]["page"]).to eq(2)
      expect(body["meta"]["total"]).to eq(30)
    end
  end

  describe "advanced conversations — negative paths" do
    it "returns 404 snoozing an unknown conversation" do
      post "/api/v1/orgs/#{org.key}/conversations/conv_missing/snooze",
           params: { until: 1.day.from_now.iso8601 }, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 merging into an unknown target" do
      conv = create(:conversation, organization: org)
      post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/merge",
           params: { target_id: "conv_missing" }, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 splitting an unknown message" do
      conv = create(:conversation, organization: org)
      post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/split",
           params: { message_id: "msg_missing" }, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "requires authentication" do
      conv = create(:conversation, organization: org)
      post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/snooze",
           params: { until: 1.day.from_now.iso8601 }
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
