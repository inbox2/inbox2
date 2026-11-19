require "rails_helper"

RSpec.describe "Api::V1::Spaces", type: :request do
  let(:owner) { create(:user, username: "spaceowner") }
  let(:org) { create(:organization, owner: owner, domain: "spaces.com") }
  let!(:owner_membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  # --- Index: seeds defaults + returns stats ---
  describe "GET /api/v1/orgs/:org_id/spaces" do
    context "positive" do
      it "auto-creates the canonical default spaces on first access" do
        get "/api/v1/orgs/#{org.key}/spaces", headers: headers
        expect(response).to have_http_status(:ok)
        slugs = response.parsed_body["spaces"].map { |s| s["slug"] }
        expect(slugs).to include("support", "sales", "marketing", "finance", "operations", "triage")
        response.parsed_body["spaces"].each { |s| expect(s["id"]).to start_with("spc_") }
      end

      it "returns per-space conversation stats" do
        Space.ensure_default_spaces(org)
        support = org.spaces.find_by!(slug: "support")
        create(:conversation, organization: org, space: support, status: "open", read: false)
        create(:conversation, organization: org, space: support, status: "open", read: true)
        # Archived = done: leaves the space's active queue, so it counts toward
        # volume (history) but never toward open/unread.
        create(:conversation, organization: org, space: support, status: "archived", read: false)
        # Trash and spam aren't real mail: they never count, not even toward volume.
        create(:conversation, organization: org, space: support, status: "trash")
        create(:conversation, organization: org, space: support, status: "spam")

        get "/api/v1/orgs/#{org.key}/spaces", headers: headers
        row = response.parsed_body["spaces"].find { |s| s["slug"] == "support" }
        expect(row["volume"]).to eq(3)
        expect(row["open"]).to eq(2)
        expect(row["unread"]).to eq(1)
        expect(row["unassigned"]).to eq(2)
      end

      it "includes staffed member summaries" do
        Space.ensure_default_spaces(org)
        sales = org.spaces.find_by!(slug: "sales")
        member_user = create(:user, username: "rep", display_name: "Sales Rep")
        m = create(:membership, user: member_user, organization: org, role: "member", status: "active")
        sales.memberships << m

        get "/api/v1/orgs/#{org.key}/spaces", headers: headers
        row = response.parsed_body["spaces"].find { |s| s["slug"] == "sales" }
        member = row["members"].find { |x| x["name"] == "Sales Rep" }
        expect(member).to be_present
        # The membership key is exposed so the settings UI can pre-check staffing.
        expect(member["key"]).to eq(m.key)
      end
    end

    context "negative" do
      it "404s for a non-member" do
        outsider = create(:user, username: "outsider")
        get "/api/v1/orgs/#{org.key}/spaces", headers: auth_headers(outsider)
        expect(response).to have_http_status(:not_found)
      end

      it "401s without auth" do
        get "/api/v1/orgs/#{org.key}/spaces"
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  # --- Create ---
  describe "POST /api/v1/orgs/:org_id/spaces" do
    context "positive" do
      it "creates a space and derives a slug from the name" do
        post "/api/v1/orgs/#{org.key}/spaces",
          params: { name: "Partnerships", icon: "person.2", openness: "org" }, headers: headers, as: :json
        expect(response).to have_http_status(:created)
        body = response.parsed_body["space"]
        expect(body["name"]).to eq("Partnerships")
        expect(body["slug"]).to eq("partnerships")
        expect(body["openness"]).to eq("org")
      end

      it "staffs members passed by membership key" do
        member_user = create(:user, username: "pmuser")
        m = create(:membership, user: member_user, organization: org, role: "member", status: "active")
        post "/api/v1/orgs/#{org.key}/spaces",
          params: { name: "Product", members: [m.key] }, headers: headers, as: :json
        expect(response).to have_http_status(:created)
        space = org.spaces.find_by!(slug: "product")
        expect(space.memberships).to include(m)
      end
    end

    context "negative" do
      it "rejects a blank name" do
        post "/api/v1/orgs/#{org.key}/spaces", params: { name: "" }, headers: headers, as: :json
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "forbids non-admin members from creating spaces" do
        plain = create(:user, username: "plainmember")
        create(:membership, user: plain, organization: org, role: "member", status: "active")
        post "/api/v1/orgs/#{org.key}/spaces", params: { name: "Nope" }, headers: auth_headers(plain), as: :json
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  # --- Update ---
  describe "PATCH /api/v1/orgs/:org_id/spaces/:id" do
    it "renames a space" do
      space = create(:space, organization: org, name: "Old", slug: "old")
      patch "/api/v1/orgs/#{org.key}/spaces/#{space.key}",
        params: { name: "New name" }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["space"]["name"]).to eq("New name")
    end

    it "accepts and returns not_for (the Jev exclusion hint)" do
      space = create(:space, organization: org, name: "Sales", slug: "sales")
      patch "/api/v1/orgs/#{org.key}/spaces/#{space.key}",
        params: { not_for: "Existing customers asking for help" }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["space"]["not_for"]).to eq("Existing customers asking for help")
      expect(space.reload.not_for).to eq("Existing customers asking for help")
    end

    it "404s for a space in another org" do
      other_org = create(:organization, owner: owner, domain: "other.com")
      foreign = create(:space, organization: other_org, slug: "foreign")
      patch "/api/v1/orgs/#{org.key}/spaces/#{foreign.key}",
        params: { name: "x" }, headers: headers, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  # --- Destroy ---
  describe "DELETE /api/v1/orgs/:org_id/spaces/:id" do
    it "deletes a space and nullifies its conversations" do
      space = create(:space, organization: org, slug: "temp")
      conv = create(:conversation, organization: org, space: space)
      delete "/api/v1/orgs/#{org.key}/spaces/#{space.key}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(Space.exists?(space.id)).to be(false)
      expect(conv.reload.space_id).to be_nil
    end
  end
end
