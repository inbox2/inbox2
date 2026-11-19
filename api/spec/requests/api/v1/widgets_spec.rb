require "rails_helper"

RSpec.describe "Api::V1::Widgets", type: :request do
  let(:owner) { create(:user, username: "wgtowner") }
  let(:org) { create(:organization, owner: owner, domain: "widgets.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:headers) { auth_headers(owner) }

  describe "GET /api/v1/orgs/:org_id/widgets (spec 14.7)" do
    it "lists widgets" do
      WidgetConfig.create!(organization: org, name: "Support Widget")
      get "/api/v1/orgs/#{org.key}/widgets", headers: headers
      expect(response).to have_http_status(:ok)
      widgets = response.parsed_body["widgets"]
      expect(widgets.length).to eq(1)
      expect(widgets.first["id"]).to start_with("wgt_")
      expect(widgets.first["widget_token"]).to start_with("wt_")
      expect(widgets.first["embed_script"]).to include("data-token")
    end
  end

  describe "POST /api/v1/orgs/:org_id/widgets" do
    it "creates a widget config" do
      post "/api/v1/orgs/#{org.key}/widgets",
           params: {
             name: "Contact Widget",
             appearance: { color: "#3366cc", position: "bottom-right" },
             behavior: { greeting: "How can we help?" },
             allowed_domains: "example.com\nmysite.io"
           },
           headers: headers
      expect(response).to have_http_status(:created)
      widget = response.parsed_body["widget"]
      expect(widget["name"]).to eq("Contact Widget")
      expect(widget["appearance"]["color"]).to eq("#3366cc")
    end

    it "forbids regular members" do
      member = create(:user, username: "wgtmember")
      create(:membership, user: member, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)
      post "/api/v1/orgs/#{org.key}/widgets",
           params: { name: "Blocked" },
           headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "DELETE /api/v1/orgs/:org_id/widgets/:id" do
    let!(:widget) { WidgetConfig.create!(organization: org, name: "To Delete") }

    it "deletes a widget config" do
      expect {
        delete "/api/v1/orgs/#{org.key}/widgets/#{widget.key}", headers: headers
      }.to change(WidgetConfig, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end
  end

  describe "GET /api/v1/widget/config/:token" do
    let!(:widget) do
      WidgetConfig.create!(
        organization: org,
        name: "Public Widget",
        appearance: { theme: "dark" },
        behavior: { auto_open: false },
        allowed_domains: "example.com"
      )
    end

    it "returns widget config without auth" do
      get "/api/v1/widget/config/#{widget.widget_token}",
          headers: { "Origin" => "https://example.com" }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["organization"]).to eq(org.name)
      expect(response.parsed_body["appearance"]["theme"]).to eq("dark")
    end

    it "returns 404 for disallowed domains (prevents token probing)" do
      get "/api/v1/widget/config/#{widget.widget_token}",
          headers: { "Origin" => "https://malicious.com" }
      expect(response).to have_http_status(:not_found)
    end

    it "allows any domain when allowed_domains is blank" do
      widget.update!(allowed_domains: nil)
      get "/api/v1/widget/config/#{widget.widget_token}",
          headers: { "Origin" => "https://anything.com" }
      expect(response).to have_http_status(:ok)
    end

    it "returns 404 for disabled widget" do
      widget.update!(status: WidgetConfig::STATUS_DISABLED)
      get "/api/v1/widget/config/#{widget.widget_token}"
      expect(response).to have_http_status(:not_found)
    end
  end
end
