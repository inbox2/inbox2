require "rails_helper"

RSpec.describe "Api::V1::MemberActivity", type: :request do
  let(:owner) { create(:user, username: "orgowner") }
  let(:org) { create(:organization, owner: owner, domain: "team.com") }
  let!(:owner_membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }
  let(:conversation) { create(:conversation, organization: org) }

  describe "GET /api/v1/orgs/:org_id/members/activity" do
    context "positive" do
      it "returns a summary card per active member with zeroed metrics when nothing is logged" do
        get "/api/v1/orgs/#{org.key}/members/activity", headers: headers
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["range"]["days"]).to eq(14)
        expect(body["activity"].length).to eq(1)
        card = body["activity"].first
        expect(card["id"]).to start_with("mbr_")
        expect(card["totals"].keys).to match_array(ActivityEvent::METRIC_ACTIONS)
        expect(card["totals"].values).to all(eq(0))
        expect(card["sparkline"].length).to eq(14)
      end

      it "tallies logged actions to the acting member and fills the sparkline" do
        ActivityEvent.log(conversation: conversation, action: ActivityEvent::ACTION_REPLIED, membership: owner_membership)
        ActivityEvent.log(conversation: conversation, action: ActivityEvent::ACTION_REPLIED, membership: owner_membership)
        ActivityEvent.log(conversation: conversation, action: ActivityEvent::ACTION_ARCHIVED, membership: owner_membership)

        get "/api/v1/orgs/#{org.key}/members/activity", headers: headers
        card = response.parsed_body["activity"].first
        expect(card["totals"][ActivityEvent::ACTION_REPLIED]).to eq(2)
        expect(card["totals"][ActivityEvent::ACTION_ARCHIVED]).to eq(1)
        expect(card["sparkline"].sum).to eq(3) # today's bucket
      end

      it "excludes events older than the window" do
        ActivityEvent.log(conversation: conversation, action: ActivityEvent::ACTION_READ, membership: owner_membership)
        ActivityEvent.where(membership: owner_membership).update_all(created_at: 30.days.ago)

        get "/api/v1/orgs/#{org.key}/members/activity", headers: headers
        card = response.parsed_body["activity"].first
        expect(card["totals"][ActivityEvent::ACTION_READ]).to eq(0)
      end
    end

    context "negative — tenant isolation (E3)" do
      it "returns 404 for an org the user does not belong to" do
        other = create(:organization, domain: "other.com")
        get "/api/v1/orgs/#{other.key}/members/activity", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "GET /api/v1/orgs/:org_id/members/:id/activity" do
    context "positive" do
      it "returns the member's action feed newest-first with conversation refs" do
        ActivityEvent.log(conversation: conversation, action: ActivityEvent::ACTION_DELETED, membership: owner_membership)

        get "/api/v1/orgs/#{org.key}/members/#{owner_membership.key}/activity", headers: headers
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["member"]["id"]).to eq(owner_membership.key)
        expect(body["feed"].first["action"]).to eq(ActivityEvent::ACTION_DELETED)
        expect(body["feed"].first["conversation"]["id"]).to eq(conversation.key)
      end
    end

    context "negative" do
      it "returns 404 for a membership key outside the org" do
        get "/api/v1/orgs/#{org.key}/members/mbr_missing/activity", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "the activity_tracking_enabled switch" do
    it "surfaces nothing (even prior events) when tracking is off" do
      ActivityEvent.log(conversation: conversation, action: ActivityEvent::ACTION_REPLIED, membership: owner_membership)
      org.update!(activity_tracking_enabled: false)

      get "/api/v1/orgs/#{org.key}/members/activity", headers: headers
      body = response.parsed_body
      expect(body["tracking_enabled"]).to be(false)
      expect(body["activity"]).to eq([])
    end

    it "records member-attributed events for actions when ON (end-to-end)" do
      post "/api/v1/orgs/#{org.key}/conversations/#{conversation.key}/archive", headers: headers
      expect(response).to have_http_status(:ok)

      get "/api/v1/orgs/#{org.key}/members/activity", headers: headers
      card = response.parsed_body["activity"].first
      expect(card["totals"][ActivityEvent::ACTION_ARCHIVED]).to eq(1)
      expect(ActivityEvent.where(membership: owner_membership, action: ActivityEvent::ACTION_ARCHIVED).count).to eq(1)
    end

    it "records nothing for actions when the switch is OFF" do
      org.update!(activity_tracking_enabled: false)
      post "/api/v1/orgs/#{org.key}/conversations/#{conversation.key}/archive", headers: headers
      expect(response).to have_http_status(:ok)
      expect(ActivityEvent.where(action: ActivityEvent::ACTION_ARCHIVED).count).to eq(0)
    end
  end
end
