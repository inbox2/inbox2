require "rails_helper"

# End-to-end visibility (E3 + spec 5.1, aa9102c0 per-domain pool access): what
# a member actually SEES after onboarding, across both scoping layers:
#
#   A. Cross-org — the console's "each domain is an org" model: invited to one
#      of the owner's three domains, the member's world is that one org; the
#      other two 404 on every org-scoped surface.
#   B. In-org domain scoping — one org owning three Domains: a member scoped
#      to a single domain sees only that domain's slice of the pool, except
#      where a direct assignment deliberately pierces the scope.
RSpec.describe "Visibility end-to-end", type: :request do
  include ActiveJob::TestHelper

  let(:owner) { create(:user, username: "visowner") }
  let(:headers) { auth_headers(owner) }

  describe "A. cross-org isolation (member on 1 of the owner's 3 domains)" do
    let!(:orgs) do
      %w[one.com two.com three.com].map do |dom|
        org = create(:organization, owner: owner, domain: dom)
        create(:membership, user: owner, organization: org, role: "owner", status: "active")
        create(:subscription, organization: org, plan: Plan.max)
        org
      end
    end

    it "invited member sees exactly their org; the others 404 everywhere" do
      # Full journey: invite to one.com only, accept via the emailed link.
      clear_enqueued_jobs
      post "/api/v1/members/invite-mx",
        params: { email: "solo@external.com", domain_ids: [orgs[0].default_domain.key] },
        headers: headers, as: :json
      expect(response).to have_http_status(:created)

      job = enqueued_jobs.reverse.find { |j| j["job_class"] == "MessyTriggerJob" }
      body = ActiveJob::Arguments.deserialize(job["arguments"]).last[:body]
      invite_id = Rack::Utils.parse_query(URI(body[%r{https?://[^"'\s]+/accept-invite\?invite=[\w-]+}]).query)["invite"]
      post "/api/v1/members/accept-invite",
        params: { invite_id: invite_id, username: "solomember", password: "a-long-password-3" }, as: :json
      expect(response).to have_http_status(:ok)
      member_headers = { "Authorization" => "Bearer #{response.parsed_body['token']}" }

      # The org switcher lists exactly one of the three domains.
      get "/api/v1/account/organizations", headers: member_headers
      names = response.parsed_body["organizations"].map { |o| o["domain"] }
      expect(names).to eq(["one.com"])

      # The member's own org works…
      get "/api/v1/orgs/#{orgs[0].key}/conversations", headers: member_headers
      expect(response).to have_http_status(:ok)

      # …the owner's other two domains are invisible on every org surface (E3: 404, not 403).
      orgs[1..].each do |other|
        get "/api/v1/orgs/#{other.key}", headers: member_headers
        expect(response).to have_http_status(:not_found)
        get "/api/v1/orgs/#{other.key}/conversations", headers: member_headers
        expect(response).to have_http_status(:not_found)
        get "/api/v1/orgs/#{other.key}/members", headers: member_headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "B. in-org domain scoping (member on 1 of an org's 3 domains)" do
    let(:org) { create(:organization, owner: owner, domain: "main.com") }
    let!(:owner_m) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
    let!(:sub) { create(:subscription, organization: org, plan: Plan.max) }
    let(:domains) { [org.default_domain, create(:domain, organization: org, name: "b.main.com"), create(:domain, organization: org, name: "c.main.com")] }
    let!(:convs) do
      domains.map { |d| create(:conversation, organization: org, domain: d, subject: "Thread on #{d.name}") }
    end

    let(:member) { create(:user, username: "scopedmember") }
    let!(:member_m) { create(:membership, user: member, organization: org, role: "member", status: "active") }
    let(:member_headers) { auth_headers(member) }

    it "a scoped member sees one domain's pool slice; direct assignment pierces it" do
      # Unscoped member sees the whole pool (all three domains).
      get "/api/v1/orgs/#{org.key}/conversations", headers: member_headers
      expect(response.parsed_body["conversations"].length).to eq(3)

      # Owner scopes the member to the first domain only.
      patch "/api/v1/orgs/#{org.key}/members/#{member_m.key}",
        params: { all_domains: false, domain_ids: [domains[0].key] }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["member"]["all_domains"]).to be(false)

      # Pool narrows to that domain's slice — 1 of 3.
      get "/api/v1/orgs/#{org.key}/conversations", headers: member_headers
      subjects = response.parsed_body["conversations"].map { |c| c["subject"] }
      expect(subjects).to eq(["Thread on #{domains[0].name}"])

      # An out-of-scope thread 404s directly too.
      get "/api/v1/orgs/#{org.key}/conversations/#{convs[1].key}", headers: member_headers
      expect(response).to have_http_status(:not_found)

      # A direct assignment on a domain-2 thread pierces the scope (one-off
      # cross-domain work) — the pool shows 2, and the thread opens.
      convs[1].conversation_assignees.create!(membership: member_m)
      get "/api/v1/orgs/#{org.key}/conversations", headers: member_headers
      expect(response.parsed_body["conversations"].length).to eq(2)
      get "/api/v1/orgs/#{org.key}/conversations/#{convs[1].key}", headers: member_headers
      expect(response).to have_http_status(:ok)

      # The owner still sees all three.
      get "/api/v1/orgs/#{org.key}/conversations", headers: headers
      expect(response.parsed_body["conversations"].length).to eq(3)
    end
  end
end
