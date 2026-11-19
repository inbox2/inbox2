require "rails_helper"

# Spec F8: an org whose plan does not include Disk gets a 403 from every Disk endpoint.
RSpec.describe "Disk plan gate", type: :request do
  include_context "disk org"

  before { org.subscription.update!(plan: Plan.free) }

  # Public link routes sit outside the org and answer 404 once Disk is gone
  # (links_spec); the MCP endpoint takes an agent credential (mcp_spec); the
  # importers' OAuth callback is outside the org and bound to a signed state.
  routes = Rails.application.routes.routes.select do |r|
    r.defaults[:controller].to_s.start_with?("api/v1/disk/") && r.path.spec.to_s.include?(":org_id") &&
      %w[api/v1/disk/public_links api/v1/disk/mcp].exclude?(r.defaults[:controller])
  end

  it "covers every Disk route" do
    expect(routes.size).to be >= 30
  end

  routes.each do |route|
    verb = route.verb.split("|").first
    it "refuses #{verb} #{route.path.spec}" do
      path = route.path.spec.to_s.sub("(.:format)", "")
        .gsub(":org_id", org.key).gsub(/:\w+/, "x")
      send(verb.downcase, path, headers: auth_headers(owner_user), as: :json)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["errors"].first["message"]).to match(/not included/)
    end
  end

  it "still 404s a non-member before the plan check" do
    get "/api/v1/orgs/#{org.key}/disk", headers: auth_headers(create(:user))
    expect(response).to have_http_status(:not_found)
  end
end
