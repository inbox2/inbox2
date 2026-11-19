require "rails_helper"

# End-to-end invite flow (spec 5.1.1, A4.2/A4.3): the whole self-service
# onboarding chain as one journey — invite → the ACTUAL rendered email → the
# accept link lifted from that email's HTML (not from the API response) →
# password-set accept → landing role → login with the new credentials.
# Catches any drift between what we email people and what the accept endpoint
# expects.
RSpec.describe "Invite flow end-to-end", type: :request do
  include ActiveJob::TestHelper

  let(:owner) { create(:user, username: "e2eowner") }
  let(:org1) { create(:organization, owner: owner, domain: "acme.com") }
  let(:org2) { create(:organization, owner: owner, domain: "acme.dev") }
  let!(:m1) { create(:membership, user: owner, organization: org1, role: "owner", status: "active") }
  let!(:m2) { create(:membership, user: owner, organization: org2, role: "owner", status: "active") }
  let!(:sub1) { create(:subscription, organization: org1, plan: Plan.max) }
  let!(:sub2) { create(:subscription, organization: org2, plan: Plan.max) }
  let(:headers) { auth_headers(owner) }

  # The last invite email handed to the Messy job: [method, {to:, subject:, body:}].
  def last_invite_email
    job = enqueued_jobs.reverse.find { |j| j["job_class"] == "MessyTriggerJob" }
    expect(job).to be_present, "no invite email was enqueued"
    args = ActiveJob::Arguments.deserialize(job["arguments"])
    expect(args.first).to eq("send_message")
    args.last
  end

  # The invite key exactly as the invitee's click would deliver it: lifted from
  # the accept URL in the email HTML (the web page passes it through verbatim).
  def invite_id_from(email_body)
    url = email_body[%r{https?://[^"'\s]+/accept-invite\?invite=[\w-]+}]
    expect(url).to be_present, "invite email carries no accept link"
    Rack::Utils.parse_query(URI(url).query)["invite"]
  end

  it "member journey: invite → email → accept from the email link → inbox landing → login works" do
    clear_enqueued_jobs

    # 1. Owner invites one person to both domains.
    post "/api/v1/members/invite-mx",
      params: { email: "jo.doe@external.com", local_part: "jo", domain_ids: [org1.default_domain.key, org2.default_domain.key] },
      headers: headers, as: :json
    expect(response).to have_http_status(:created)

    # 2. Exactly one email, to the invitee, naming every new mailbox.
    email = last_invite_email
    expect(email[:to]).to eq("jo.doe@external.com")
    expect(email[:subject]).to include("acme.com")
    expect(email[:body]).to include("jo@acme.com").and include("jo@acme.dev")
    expect(email[:body]).to include(owner.username)

    # 3. Follow the email's own link, set credentials (unauthenticated).
    post "/api/v1/members/accept-invite",
      params: { invite_id: invite_id_from(email[:body]),
                username: "jodoe", password: "a-long-password-1" }, as: :json
    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["token"]).to be_present
    expect(body["admin"]).to be(false) # member → straight to the inbox

    # 4. BOTH invites activated, mailboxes live on each domain.
    jo = User.find_by(username: "jodoe")
    expect(jo.memberships.where(status: Membership::STATUS_ACTIVE).count).to eq(2)
    expect(jo.memberships.flat_map(&:email_addresses)).to contain_exactly("jo@acme.com", "jo@acme.dev")

    # 5. The password set during accept is a real login credential.
    post "/api/v1/auth/login", params: { username: "jodoe", password: "a-long-password-1" }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["token"]).to be_present
  end

  it "admin journey: the accept response routes managers to the console" do
    clear_enqueued_jobs
    post "/api/v1/members/invite-mx",
      params: { email: "boss@external.com", role: "admin", domain_ids: [org1.default_domain.key] },
      headers: headers, as: :json
    expect(response).to have_http_status(:created)

    post "/api/v1/members/accept-invite",
      params: { invite_id: invite_id_from(last_invite_email[:body]),
                username: "bossuser", password: "a-long-password-2" }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["admin"]).to be(true) # admin → /console
  end

  it "existing-account journey: unauthenticated accept bounces to login; authenticated accept activates" do
    existing = create(:user, username: "veteran", password: "old-password-9", billing_email: "vet@external.com")
    vet_org = create(:organization, owner: existing, domain: "vet.com")
    create(:membership, user: existing, organization: vet_org, role: "owner", status: "active")

    clear_enqueued_jobs
    post "/api/v1/members/invite-mx",
      params: { email: "vet@external.com", domain_ids: [org1.default_domain.key] },
      headers: headers, as: :json
    expect(response).to have_http_status(:created)
    invite_id = invite_id_from(last_invite_email[:body])

    # Claimed account + no session → 401 (the web page bounces through /login).
    post "/api/v1/members/accept-invite",
      params: { invite_id: invite_id, username: "ignored", password: "ignored-too" }, as: :json
    expect(response).to have_http_status(:unauthorized)

    # Back from login with a session: invites activate, credentials untouched.
    post "/api/v1/members/accept-invite",
      params: { invite_id: invite_id }, headers: auth_headers(existing), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["admin"]).to be(true) # owner of vet.com → console
    expect(existing.reload.memberships.where(organization: org1, status: Membership::STATUS_ACTIVE)).to exist

    post "/api/v1/auth/login", params: { username: "veteran", password: "old-password-9" }
    expect(response).to have_http_status(:ok)
  end
end
