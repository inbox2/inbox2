require "rails_helper"

# Registered applications — console CRUD (docs/App-OAuth.md).
# E1 mapping: A3 org-scoped admin resource; E3 tenant isolation; E5 public ids.
RSpec.describe "Api::V1::OauthApps", type: :request do
  let(:admin) { create(:user) }
  let(:org) { create(:organization, owner: admin) }
  let(:headers) { auth_headers(admin) }

  before { create(:membership, user: admin, organization: org, role: "owner", status: "active") }

  def valid_params(overrides = {})
    { name: "Partner CRM", redirect_uris: ["https://crm.example.com/oauth/inbox2"] }.merge(overrides)
  end

  describe "POST /api/v1/orgs/:org_id/oauth-apps" do
    context "positive" do
      it "registers an application and returns a prefixed public id" do
        expect {
          post "/api/v1/orgs/#{org.key}/oauth-apps", params: valid_params, headers: headers
        }.to change(OauthApp, :count).by(1)

        expect(response).to have_http_status(:created)
        app = response.parsed_body["oauth_app"]
        expect(app["id"]).to start_with("oap_")
        expect(app["name"]).to eq("Partner CRM")
        expect(app["redirect_uris"]).to eq(["https://crm.example.com/oauth/inbox2"])
        expect(app["icon_url"]).to be_nil
        expect(OauthApp.last.created_by).to eq(admin)
      end

      it "accepts several callbacks so one app can run in several environments" do
        post "/api/v1/orgs/#{org.key}/oauth-apps",
             params: valid_params(redirect_uris: [
               "https://crm.example.com/oauth/inbox2",
               "https://staging.crm.example.com/oauth/inbox2",
               "http://localhost:3000/oauth/inbox2"
             ]),
             headers: headers

        expect(response).to have_http_status(:created)
        expect(response.parsed_body["oauth_app"]["redirect_uris"].size).to eq(3)
      end

      it "accepts a newline-separated list (the console textarea / curl shape)" do
        post "/api/v1/orgs/#{org.key}/oauth-apps",
             params: valid_params(redirect_uris: "https://a.example.com/cb\nhttps://b.example.com/cb"),
             headers: headers

        expect(response).to have_http_status(:created)
        expect(response.parsed_body["oauth_app"]["redirect_uris"])
          .to eq(["https://a.example.com/cb", "https://b.example.com/cb"])
      end
    end

    context "negative" do
      it "rejects a plaintext (non-loopback) callback" do
        post "/api/v1/orgs/#{org.key}/oauth-apps",
             params: valid_params(redirect_uris: ["http://crm.example.com/cb"]), headers: headers

        expect(response).to have_http_status(:unprocessable_content)
        expect(OauthApp.count).to eq(0)
      end

      it "rejects an app with no callback at all" do
        post "/api/v1/orgs/#{org.key}/oauth-apps", params: valid_params(redirect_uris: []), headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "rejects a duplicate name within the org" do
        create(:oauth_app, organization: org, name: "Partner CRM")
        post "/api/v1/orgs/#{org.key}/oauth-apps", params: valid_params, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "requires an admin role" do
        member = create(:user)
        create(:membership, user: member, organization: org, role: "member", status: "active")
        post "/api/v1/orgs/#{org.key}/oauth-apps", params: valid_params, headers: auth_headers(member)
        expect(response).to have_http_status(:forbidden)
      end

      it "requires authentication" do
        post "/api/v1/orgs/#{org.key}/oauth-apps", params: valid_params
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe "GET /api/v1/orgs/:org_id/oauth-apps" do
    it "lists only this org's applications" do
      create(:oauth_app, organization: org, name: "Mine")
      create(:oauth_app, name: "Someone else's")

      get "/api/v1/orgs/#{org.key}/oauth-apps", headers: headers

      expect(response).to have_http_status(:ok)
      names = response.parsed_body["oauth_apps"].map { |a| a["name"] }
      expect(names).to eq(["Mine"])
    end

    it "404s for an org the caller is not a member of (E3)" do
      other = create(:organization)
      get "/api/v1/orgs/#{other.key}/oauth-apps", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH/DELETE /api/v1/orgs/:org_id/oauth-apps/:id" do
    let!(:oauth_app) { create(:oauth_app, organization: org) }

    it "updates the callback whitelist" do
      patch "/api/v1/orgs/#{org.key}/oauth-apps/#{oauth_app.key}",
            params: { redirect_uris: ["https://new.example.com/cb"] }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(oauth_app.reload.redirect_uris).to eq(["https://new.example.com/cb"])
    end

    it "deletes the application" do
      expect {
        delete "/api/v1/orgs/#{org.key}/oauth-apps/#{oauth_app.key}", headers: headers
      }.to change(OauthApp, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end

    it "404s on another org's application (E3)" do
      foreign = create(:oauth_app)
      delete "/api/v1/orgs/#{org.key}/oauth-apps/#{foreign.key}", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(foreign.reload).to be_persisted
    end
  end

  describe "GET /api/v1/oauth/apps/:app_id/icon" do
    it "404s when the app has no icon (public route, no auth needed)" do
      registered = create(:oauth_app, organization: org)
      get "/api/v1/oauth/apps/#{registered.key}/icon"
      expect(response).to have_http_status(:not_found)
    end
  end
end
