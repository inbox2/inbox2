require "rails_helper"

# CRUD for org calendars (per-member scoping via Calendar.for_member)
# E1 mapping: Calendar module — calendars CRUD (no dedicated A-number in the reference table)
RSpec.describe "Api::V1::Calendars", type: :request do
  let(:owner) { create(:user, username: "calowner") }
  let(:org) { create(:organization, owner: owner, domain: "cal.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:headers) { auth_headers(owner) }

  # A second member, to prove per-member isolation
  let(:other) { create(:user, username: "calother") }
  let!(:other_membership) { create(:membership, user: other, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE) }

  describe "GET /api/v1/orgs/:org_id/calendars" do
    context "positive" do
      it "lists the member's own and org-wide calendars, ordered by name" do
        org.calendars.create!(name: "Zeta", membership: membership)
        org.calendars.create!(name: "Alpha", membership: nil) # org-wide
        org.calendars.create!(name: "Hidden", membership: other_membership) # belongs to someone else

        get "/api/v1/orgs/#{org.key}/calendars", headers: headers
        expect(response).to have_http_status(:ok)
        names = response.parsed_body["calendars"].map { |c| c["name"] }
        # "Calendar" is the member's auto-provisioned default (Calendar.primary_for).
        expect(names).to eq(["Alpha", Calendar::DEFAULT_NAME, "Zeta"])
      end

      it "provisions a primary calendar for a member who has none" do
        expect { get "/api/v1/orgs/#{org.key}/calendars", headers: headers }
          .to change { org.calendars.where(membership: membership, is_primary: true).count }.from(0).to(1)

        expect(response.parsed_body["calendars"].map { |c| c["name"] }).to eq([Calendar::DEFAULT_NAME])
      end

      it "does not provision a second primary calendar on repeat calls" do
        get "/api/v1/orgs/#{org.key}/calendars", headers: headers
        expect { get "/api/v1/orgs/#{org.key}/calendars", headers: headers }
          .not_to change { org.calendars.count }
      end
    end

    context "negative" do
      it "requires authentication" do
        get "/api/v1/orgs/#{org.key}/calendars"
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe "GET /api/v1/orgs/:org_id/calendars/:id" do
    context "positive" do
      it "returns a calendar the member can see" do
        cal = org.calendars.create!(name: "Work", membership: membership)
        get "/api/v1/orgs/#{org.key}/calendars/#{cal.key}", headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["calendar"]["name"]).to eq("Work")
      end
    end

    context "negative" do
      it "returns 404 for an unknown calendar key" do
        get "/api/v1/orgs/#{org.key}/calendars/cal_missing", headers: headers
        expect(response).to have_http_status(:not_found)
      end

      it "returns 404 for another member's calendar" do
        cal = org.calendars.create!(name: "Private", membership: other_membership)
        get "/api/v1/orgs/#{org.key}/calendars/#{cal.key}", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "POST /api/v1/orgs/:org_id/calendars" do
    context "positive" do
      it "creates a calendar assigned to the current membership" do
        expect {
          post "/api/v1/orgs/#{org.key}/calendars",
               params: { name: "Personal", color: "#FF0000" }, headers: headers
        }.to change(org.calendars, :count).by(1)

        expect(response).to have_http_status(:created)
        body = response.parsed_body["calendar"]
        expect(body["id"]).to start_with("cal_")
        expect(body["name"]).to eq("Personal")
        expect(body["status"]).to eq(Calendar::STATUS_ACTIVE)
        expect(body["membership_id"]).to eq(membership.key)
      end
    end

    context "negative" do
      it "returns 422 when name is missing" do
        post "/api/v1/orgs/#{org.key}/calendars", params: { color: "#FF0000" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "returns 404 for an org the user is not a member of" do
        stranger = create(:user, username: "calstranger")
        stranger_org = create(:organization, owner: stranger, domain: "stranger.com")
        create(:membership, user: stranger, organization: stranger_org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE)

        post "/api/v1/orgs/#{stranger_org.key}/calendars", params: { name: "X" }, headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "PATCH /api/v1/orgs/:org_id/calendars/:id" do
    context "positive" do
      it "updates a calendar" do
        cal = org.calendars.create!(name: "Old", membership: membership)
        patch "/api/v1/orgs/#{org.key}/calendars/#{cal.key}",
              params: { name: "New", is_visible: false }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["calendar"]["name"]).to eq("New")
        expect(cal.reload.is_visible).to be false
      end
    end

    context "negative" do
      it "returns 422 when name is blanked" do
        cal = org.calendars.create!(name: "Keep", membership: membership)
        patch "/api/v1/orgs/#{org.key}/calendars/#{cal.key}", params: { name: "" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "returns 404 for another member's calendar" do
        cal = org.calendars.create!(name: "Theirs", membership: other_membership)
        patch "/api/v1/orgs/#{org.key}/calendars/#{cal.key}", params: { name: "Hijack" }, headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "DELETE /api/v1/orgs/:org_id/calendars/:id" do
    context "positive" do
      it "deletes a calendar" do
        cal = org.calendars.create!(name: "Trash", membership: membership)
        expect {
          delete "/api/v1/orgs/#{org.key}/calendars/#{cal.key}", headers: headers
        }.to change(org.calendars, :count).by(-1)
        expect(response).to have_http_status(:no_content)
      end
    end

    context "negative" do
      it "returns 404 for an unknown calendar key" do
        delete "/api/v1/orgs/#{org.key}/calendars/cal_missing", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
