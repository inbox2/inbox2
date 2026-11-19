require "rails_helper"

RSpec.describe "Api::V1::Tags", type: :request do
  let(:owner) { create(:user, username: "tagowner") }
  let(:org) { create(:organization, owner: owner, domain: "tags.com") }
  let!(:owner_membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  # --- Spec 6.2.1, A9.1 — List tags ---
  describe "GET /api/v1/orgs/:org_id/tags" do
    context "positive" do
      it "lists all tags in the organization" do
        create(:tag, organization: org, name: "Billing", color: "#FF0000")
        create(:tag, organization: org, name: "Support", color: "#00FF00")

        get "/api/v1/orgs/#{org.key}/tags", headers: headers
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        names = body["tags"].map { |t| t["name"] }
        # The 2 user tags plus the system priority tags (ensured on read).
        expect(names).to contain_exactly("Billing", "Support", "Urgent", "Important", "Later")
        # Sorted by name
        expect(names).to eq(names.sort)
        # E5: public IDs only
        body["tags"].each do |t|
          expect(t["id"]).to start_with("tag_")
          expect(t).not_to have_key("organization_id")
        end
      end

      it "ensures system priority tags exist even when no user tags were created" do
        get "/api/v1/orgs/#{org.key}/tags", headers: headers
        expect(response).to have_http_status(:ok)
        names = response.parsed_body["tags"].map { |t| t["name"] }
        expect(names).to contain_exactly("Urgent", "Important", "Later")
      end
    end

    context "negative — tenant isolation (E3)" do
      it "returns 404 for a different org" do
        other_user = create(:user, username: "tagother")
        other_org = create(:organization, owner: other_user, domain: "othertags.com")
        create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")
        create(:tag, organization: other_org, name: "Secret")

        get "/api/v1/orgs/#{other_org.key}/tags", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end

    context "negative — unauthorized" do
      it "rejects unauthenticated request" do
        get "/api/v1/orgs/#{org.key}/tags"
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  # --- Spec 6.2.1, A9.1 — Create tag ---
  describe "POST /api/v1/orgs/:org_id/tags" do
    context "positive" do
      it "creates a tag" do
        expect {
          post "/api/v1/orgs/#{org.key}/tags",
               params: { name: "Finance", color: "#4CAF50" },
               headers: headers
        }.to change(Tag, :count).by(1)

        expect(response).to have_http_status(:created)
        body = response.parsed_body
        expect(body["tag"]["name"]).to eq("Finance")
        expect(body["tag"]["color"]).to eq("#4CAF50")
        expect(body["tag"]["id"]).to start_with("tag_")
      end

      it "uses default color when not specified" do
        post "/api/v1/orgs/#{org.key}/tags",
             params: { name: "NoColor" },
             headers: headers
        expect(response).to have_http_status(:created)
        expect(response.parsed_body["tag"]["color"]).to eq("#6B7280")
      end
    end

    context "negative — duplicate name" do
      it "rejects duplicate tag name in same org" do
        create(:tag, organization: org, name: "Duplicate")
        post "/api/v1/orgs/#{org.key}/tags",
             params: { name: "Duplicate" },
             headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    context "negative — role check" do
      it "forbids regular members from creating tags" do
        member = create(:user, username: "tagmember")
        create(:membership, user: member, organization: org, role: "member", status: "active")
        member_headers = auth_headers(member)

        post "/api/v1/orgs/#{org.key}/tags",
             params: { name: "Blocked" },
             headers: member_headers
        expect(response).to have_http_status(:forbidden)
      end
    end

    context "negative — missing name" do
      it "rejects tag without a name" do
        post "/api/v1/orgs/#{org.key}/tags",
             params: { color: "#FF0000" },
             headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  # --- Spec 6.2.1, A9.1 — Update tag ---
  describe "PATCH /api/v1/orgs/:org_id/tags/:id" do
    let!(:tag) { create(:tag, organization: org, name: "Old", color: "#000000") }

    context "positive" do
      it "updates a tag's name and color" do
        patch "/api/v1/orgs/#{org.key}/tags/#{tag.key}",
              params: { name: "New", color: "#FF5722" },
              headers: headers
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["tag"]["name"]).to eq("New")
        expect(body["tag"]["color"]).to eq("#FF5722")
      end
    end

    context "negative — tenant isolation (E3)" do
      it "returns 404 for a tag in another org" do
        other_user = create(:user, username: "tagiso")
        other_org = create(:organization, owner: other_user, domain: "iso.com")
        create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")
        other_tag = create(:tag, organization: other_org, name: "Foreign")

        patch "/api/v1/orgs/#{org.key}/tags/#{other_tag.key}",
              params: { name: "Stolen" },
              headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end

    context "negative — role check" do
      it "forbids regular members from updating tags" do
        member = create(:user, username: "tageditor")
        create(:membership, user: member, organization: org, role: "member", status: "active")
        member_headers = auth_headers(member)

        patch "/api/v1/orgs/#{org.key}/tags/#{tag.key}",
              params: { name: "Hacked" },
              headers: member_headers
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  # --- Spec 6.2.1, A9.1 — Delete tag ---
  describe "DELETE /api/v1/orgs/:org_id/tags/:id" do
    let!(:tag) { create(:tag, organization: org, name: "Deletable") }

    context "positive" do
      it "deletes a tag" do
        expect {
          delete "/api/v1/orgs/#{org.key}/tags/#{tag.key}", headers: headers
        }.to change(Tag, :count).by(-1)
        expect(response).to have_http_status(:no_content)
      end
    end

    context "negative — tenant isolation (E3)" do
      it "returns 404 for a tag in another org" do
        other_user = create(:user, username: "tagdel")
        other_org = create(:organization, owner: other_user, domain: "del.com")
        create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")
        other_tag = create(:tag, organization: other_org, name: "Protected")

        delete "/api/v1/orgs/#{org.key}/tags/#{other_tag.key}", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end

    context "negative — role check" do
      it "forbids regular members from deleting tags" do
        member = create(:user, username: "tagdeleter")
        create(:membership, user: member, organization: org, role: "member", status: "active")
        member_headers = auth_headers(member)

        delete "/api/v1/orgs/#{org.key}/tags/#{tag.key}", headers: member_headers
        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
