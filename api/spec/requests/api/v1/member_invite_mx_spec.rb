require "rails_helper"

# invite-mx invites one person to a private mailbox on one or more of the inviter's
# domains at once. `domain_ids` are Domain keys: each address lands on that exact
# domain. One invited membership per org; a mailbox per selected domain.
RSpec.describe "Api::V1::Members MX invites", type: :request do
  include ActiveJob::TestHelper
  let(:owner) { create(:user, username: "mxowner") }
  let(:org1) { create(:organization, owner: owner, domain: "domain1.com") }
  let(:org2) { create(:organization, owner: owner, domain: "domain2.com") }
  let!(:m1) { create(:membership, user: owner, organization: org1, role: "owner", status: "active") }
  let!(:m2) { create(:membership, user: owner, organization: org2, role: "owner", status: "active") }
  # Serial tier so the collaborator cap (Free = 0 seats) doesn't gate these invite-flow tests.
  let!(:sub1) { create(:subscription, organization: org1, plan: Plan.max) }
  let!(:sub2) { create(:subscription, organization: org2, plan: Plan.max) }
  let(:headers) { auth_headers(owner) }

  # The invite token exactly as the invitee's click delivers it: lifted from the
  # accept link in the queued email, since the API response deliberately carries
  # only the membership key (which is not an invite credential).
  def invite_token_from_email
    job = enqueued_jobs.reverse.find { |j| j["job_class"] == "MessyTriggerJob" }
    body = ActiveJob::Arguments.deserialize(job["arguments"]).last[:body]
    Rack::Utils.parse_query(URI(body[%r{https?://[^"'\s]+/accept-invite\?invite=[\w-]+}]).query)["invite"]
  end

  describe "POST /api/v1/members/invite-mx" do
    it "creates an invited membership on each selected domain" do
      post "/api/v1/members/invite-mx",
        params: { email: "newhire@external.com", domain_ids: [org1.default_domain.key, org2.default_domain.key] },
        headers: headers, as: :json
      expect(response).to have_http_status(:created)
      invites = response.parsed_body["invites"]
      expect(invites.length).to eq(2)
      expect(invites.map { |i| i["status"] }).to all(eq("invited"))
    end

    it "provisions the requested mailbox on each domain and emails the invite" do
      expect {
        post "/api/v1/members/invite-mx",
          params: { email: "newhire@external.com", local_part: "hire", domain_ids: [org1.default_domain.key, org2.default_domain.key] },
          headers: headers, as: :json
      }.to have_enqueued_job(MessyTriggerJob)
      expect(response).to have_http_status(:created)
      addresses = response.parsed_body["invites"].flat_map { |i| i["email_addresses"] }
      expect(addresses).to contain_exactly("hire@domain1.com", "hire@domain2.com")
    end

    it "derives the mailbox name from the invitee's address when none is given" do
      post "/api/v1/members/invite-mx",
        params: { email: "Jo.Doe@external.com", domain_ids: [org1.default_domain.key] },
        headers: headers, as: :json
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["invites"].first["email_addresses"]).to eq(["jo.doe@domain1.com"])
    end

    it "places the mailbox on the selected domain, not the org's default" do
      second = org1.domains.create!(name: "second.com", status: Domain::STATUS_RECEIVING_MAIL)
      post "/api/v1/members/invite-mx",
        params: { email: "hire@external.com", local_part: "hire", domain_ids: [second.key] },
        headers: headers, as: :json
      expect(response).to have_http_status(:created)
      invites = response.parsed_body["invites"]
      # One membership on org1 (not the default domain1.com), address on second.com.
      expect(invites.length).to eq(1)
      expect(invites.first["email_addresses"]).to eq(["hire@second.com"])
    end

    it "adds a mailbox to an existing member instead of skipping them" do
      existing_user = create(:user, username: "already", billing_email: "already@external.com")
      create(:membership, user: existing_user, organization: org1, role: "member", status: "active")
      second = org1.domains.create!(name: "second.com", status: Domain::STATUS_RECEIVING_MAIL)
      post "/api/v1/members/invite-mx",
        params: { email: "already@external.com", local_part: "already", domain_ids: [second.key] },
        headers: headers, as: :json
      expect(response).to have_http_status(:created)
      addrs = existing_user.memberships.flat_map(&:mailboxes).map(&:email_address)
      expect(addrs).to include("already@second.com")
    end

    it "rejects a mailbox name already taken on the domain" do
      taken = create(:membership, user: create(:user, username: "taken"), organization: org1, role: "member", status: "active")
      Mailbox.create!(membership: taken, domain: org1.default_domain, local_part: "hire")
      expect {
        post "/api/v1/members/invite-mx",
          params: { email: "newhire@external.com", local_part: "hire", domain_ids: [org1.default_domain.key] },
          headers: headers, as: :json
      }.not_to have_enqueued_job(MessyTriggerJob)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects inviting to a domain the user doesn't manage" do
      stranger_org = create(:organization, owner: create(:user, username: "stranger"), domain: "notmine.com")
      post "/api/v1/members/invite-mx",
        params: { email: "x@external.com", domain_ids: [org1.default_domain.key, stranger_org.default_domain.key] },
        headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    context "grant ceiling" do
      let(:admin) { create(:user, username: "mxadmin") }
      let!(:admin_m1) { create(:membership, user: admin, organization: org1, role: "admin", status: "active") }
      let(:admin_headers) { auth_headers(admin) }

      it "forbids an admin from inviting as admin" do
        post "/api/v1/members/invite-mx",
          params: { email: "a@external.com", domain_ids: [org1.default_domain.key], role: "admin" },
          headers: admin_headers, as: :json
        expect(response).to have_http_status(:forbidden)
      end

      it "lets an admin invite a member" do
        post "/api/v1/members/invite-mx",
          params: { email: "b@external.com", domain_ids: [org1.default_domain.key], role: "member" },
          headers: admin_headers, as: :json
        expect(response).to have_http_status(:created)
        expect(response.parsed_body["invites"].first["role"]).to eq("member")
      end
    end
  end

  describe "POST /api/v1/members/accept-invite activates every pending invite" do
    it "turns all invited memberships active so the user gets each domain's tab" do
      post "/api/v1/members/invite-mx",
        params: { email: "multi@external.com", domain_ids: [org1.default_domain.key, org2.default_domain.key] },
        headers: headers, as: :json
      invite_id = invite_token_from_email

      post "/api/v1/members/accept-invite",
        params: { invite_id: invite_id, username: "multiuser", password: "supersecret1" }, as: :json
      expect(response).to have_http_status(:ok)

      invited_user = User.find_by(username: "multiuser")
      expect(invited_user.memberships.where(status: "active").count).to eq(2)
      expect(invited_user.accessible_organizations.map { |o| o.default_domain.name }).to contain_exactly("domain1.com", "domain2.com")
    end

    it "reports whether the accepter is a manager anywhere (drives the landing page)" do
      post "/api/v1/members/invite-mx",
        params: { email: "plain@external.com", domain_ids: [org1.default_domain.key] },
        headers: headers, as: :json
      invite_id = invite_token_from_email
      post "/api/v1/members/accept-invite",
        params: { invite_id: invite_id, username: "plainuser", password: "supersecret1" }, as: :json
      expect(response.parsed_body["admin"]).to be(false)

      post "/api/v1/members/invite-mx",
        params: { email: "boss@external.com", domain_ids: [org2.default_domain.key], role: "admin" },
        headers: headers, as: :json
      invite_id = invite_token_from_email
      post "/api/v1/members/accept-invite",
        params: { invite_id: invite_id, username: "bossuser", password: "supersecret1" }, as: :json
      expect(response.parsed_body["admin"]).to be(true)
    end
  end
end
