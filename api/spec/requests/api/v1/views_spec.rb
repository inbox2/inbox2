require "rails_helper"

RSpec.describe "Api::V1::Views", type: :request do
  let(:owner) { create(:user, username: "viewowner") }
  let(:org) { create(:organization, owner: owner, domain: "views.com") }
  let!(:owner_membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  # --- Spec 3.2.x, A10.1 — List views ---
  describe "GET /api/v1/orgs/:org_id/views" do
    context "positive" do
      it "returns system views and personal views" do
        create(:view, organization: org, membership: owner_membership, name: "My Custom View", kind: "personal")

        get "/api/v1/orgs/#{org.key}/views", headers: headers
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        # System views auto-created + 1 personal
        system_count = View::SYSTEM_VIEWS.length
        expect(body["views"].length).to eq(system_count + 1)
        body["views"].each { |v| expect(v["id"]).to start_with("view_") }
      end

      it "creates system views on first access (spec 3.2.1-3.2.6)" do
        get "/api/v1/orgs/#{org.key}/views", headers: headers
        expect(response).to have_http_status(:ok)
        names = response.parsed_body["views"].map { |v| v["name"] }
        expect(names).to include("Inbox", "All Mail", "Mentioned", "Unassigned", "Sent", "Drafts")
      end

      it "does not show other members' personal views" do
        other = create(:user, username: "viewother")
        other_membership = create(:membership, user: other, organization: org, role: "member", status: "active")
        create(:view, organization: org, membership: other_membership, name: "Their View", kind: "personal")

        get "/api/v1/orgs/#{org.key}/views", headers: headers
        names = response.parsed_body["views"].map { |v| v["name"] }
        expect(names).not_to include("Their View")
      end
    end

    context "negative — tenant isolation (E3)" do
      it "returns 404 for another org" do
        other_user = create(:user, username: "viewiso")
        other_org = create(:organization, owner: other_user, domain: "viewiso.com")
        create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")

        get "/api/v1/orgs/#{other_org.key}/views", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # --- Spec 3.3.1, A10.2 — Create personal view ---
  describe "POST /api/v1/orgs/:org_id/views" do
    context "positive" do
      it "creates a personal saved view with filter criteria" do
        post "/api/v1/orgs/#{org.key}/views",
             params: {
               name: "VIP Customers",
               filters: [{ field: "tag", operator: "equals", value: "vip" }],
               icon: "star"
             },
             headers: headers
        expect(response).to have_http_status(:created)
        body = response.parsed_body
        expect(body["view"]["name"]).to eq("VIP Customers")
        expect(body["view"]["kind"]).to eq("personal")
        expect(body["view"]["filters"]).to be_an(Array)
        expect(body["view"]["icon"]).to eq("star")
      end

      it "supports AND logic with multiple filter criteria (spec 3.3.3)" do
        post "/api/v1/orgs/#{org.key}/views",
             params: {
               name: "Open + Tagged",
               filters: [
                 { field: "status", operator: "equals", value: "open" },
                 { field: "tag", operator: "equals", value: "urgent" }
               ]
             },
             headers: headers
        expect(response).to have_http_status(:created)
        expect(response.parsed_body["view"]["filters"].length).to eq(2)
      end
    end

    context "negative — admins_only policy (spec 3.3.1, A10.8)" do
      before { org.update!(view_creation_policy: "admins_only") }

      it "forbids regular members from creating views" do
        member = create(:user, username: "viewmember")
        create(:membership, user: member, organization: org, role: "member", status: "active")

        post "/api/v1/orgs/#{org.key}/views",
             params: { name: "Blocked View", filters: [] },
             headers: auth_headers(member)
        expect(response).to have_http_status(:forbidden)
      end

      it "allows admins to create views" do
        post "/api/v1/orgs/#{org.key}/views",
             params: { name: "Admin View", filters: [] },
             headers: headers
        expect(response).to have_http_status(:created)
      end
    end
  end

  # --- Spec A10.3 — Update/delete view ---
  describe "PATCH /api/v1/orgs/:org_id/views/:id" do
    let!(:view) { create(:view, organization: org, membership: owner_membership, name: "Old Name", kind: "personal") }

    it "updates a personal view" do
      patch "/api/v1/orgs/#{org.key}/views/#{view.key}",
            params: { name: "New Name" },
            headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["view"]["name"]).to eq("New Name")
    end

    it "cannot update system views" do
      View.ensure_system_views(org)
      system_view = org.views.system_views.first

      patch "/api/v1/orgs/#{org.key}/views/#{system_view.key}",
            params: { name: "Hacked" },
            headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/v1/orgs/:org_id/views/:id" do
    let!(:view) { create(:view, organization: org, membership: owner_membership, name: "Deletable", kind: "personal") }

    it "deletes a personal view" do
      expect {
        delete "/api/v1/orgs/#{org.key}/views/#{view.key}", headers: headers
      }.to change(View, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end
  end

  # --- Spec 3.3.1, A10.8 — View policy ---
  describe "PUT /api/v1/orgs/:org_id/settings/view-policy" do
    it "updates the view creation policy" do
      put "/api/v1/orgs/#{org.key}/settings/view-policy",
          params: { view_creation_policy: "admins_only" },
          headers: headers
      expect(response).to have_http_status(:ok)
      expect(org.reload.view_creation_policy).to eq("admins_only")
    end

    it "rejects invalid policy" do
      put "/api/v1/orgs/#{org.key}/settings/view-policy",
          params: { view_creation_policy: "invalid" },
          headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "forbids non-admin members" do
      member = create(:user, username: "policymember")
      create(:membership, user: member, organization: org, role: "member", status: "active")

      put "/api/v1/orgs/#{org.key}/settings/view-policy",
          params: { view_creation_policy: "admins_only" },
          headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
