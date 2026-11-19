require "rails_helper"

# End-to-end journey for per-domain pool access, driven entirely through the HTTP
# API with real login → bearer auth: an owner adds a second domain, scopes a
# member to only that domain, real inbound mail lands on each domain, and the
# member sees only their slice (list / open / offline-sync) while the owner sees
# the whole pool — plus the direct-assignment override, per-domain stats, and the
# zero-grant guard. This exercises the full stack, not just the model.
RSpec.describe "E2E: per-domain pool access", type: :request do
  # Real login (POST /auth/login) → bearer token. Proves the auth endpoint and
  # gives each actor its own credentials, exactly like the clients.
  def login(username, password = "password123")
    post "/api/v1/auth/login", params: { username: username, password: password }
    expect(response).to have_http_status(:ok), "login failed for #{username}: #{response.body}"
    { "Authorization" => "Bearer #{response.parsed_body['token']}" }
  end

  # Land a real inbound email on a domain through the actual pipeline.
  def inbound_to(domain_name, subject:, from: "outsider@world.test")
    payload = {
      "envelope" => { "mail_from" => from, "rcpt_to" => ["team@#{domain_name}"], "client_ip" => "203.0.113.5" },
      "headers" => { "from" => "Sender <#{from}>", "to" => "team@#{domain_name}", "subject" => subject,
                     "content_type" => "text/plain", "message_id" => "<#{SecureRandom.hex(4)}@world.test>" },
      "body" => { "plain" => "hello there", "html" => "" },
      "attachments" => [],
      "authentication" => { "dmarc" => { "result" => "pass", "policy" => "none" } },
      "raw_message_b64" => ""
    }
    InboundMailProcessor.new(payload).process
  end

  let!(:owner) { create(:user, username: "e2e_owner") }
  let!(:org) { create(:organization, owner: owner, domain: "alpha.test") }
  let!(:owner_m) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  # Paid plan so the org may own more than one domain (Free = 1).
  let!(:sub) { create(:subscription, organization: org, plan: Plan.max) }
  let!(:member_user) { create(:user, username: "e2e_member") }
  let!(:member_m) { create(:membership, user: member_user, organization: org, role: "member", status: "active") }

  it "walks the full domain-scoped journey end to end" do
    owner_h  = login("e2e_owner")
    member_h = login("e2e_member")

    # 1. Owner adds a second domain through the API.
    post "/api/v1/orgs/#{org.key}/domains", params: { domain: "beta.test" }, headers: owner_h
    expect(response).to have_http_status(:created)
    alpha = org.default_domain
    beta  = org.domains.find_by(key: response.parsed_body["domain"]["id"])
    [alpha, beta].each { |d| d.update!(status: Domain::STATUS_VERIFIED) }

    # 2. Owner scopes the member to beta only (Team API).
    patch "/api/v1/orgs/#{org.key}/members/#{member_m.key}",
      params: { all_domains: false, domain_ids: [beta.key] }, headers: owner_h
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["member"]["all_domains"]).to be(false)
    expect(response.parsed_body["member"]["domains"].map { |d| d["name"] }).to eq(["beta.test"])

    # 3. Real inbound mail lands on each domain.
    inbound_to("alpha.test", subject: "alpha-thread")
    inbound_to("beta.test",  subject: "beta-thread")
    expect(org.conversations.count).to eq(2)

    # 4. The scoped member sees only beta; the owner sees both.
    get "/api/v1/orgs/#{org.key}/conversations", headers: member_h
    expect(response.parsed_body["conversations"].map { |c| c["subject"] }).to contain_exactly("beta-thread")
    get "/api/v1/orgs/#{org.key}/conversations", headers: owner_h
    expect(response.parsed_body["conversations"].map { |c| c["subject"] }).to contain_exactly("alpha-thread", "beta-thread")

    # 5. The member can't open the alpha thread…
    alpha_conv = org.conversations.find_by!(subject: "alpha-thread")
    get "/api/v1/orgs/#{org.key}/conversations/#{alpha_conv.key}", headers: member_h
    expect(response).to have_http_status(:not_found)

    # 6. …until the owner assigns it to them (direct assignment overrides scoping).
    put "/api/v1/orgs/#{org.key}/conversations/#{alpha_conv.key}/assignees",
      params: { member_ids: [member_m.key] }, headers: owner_h
    expect(response).to have_http_status(:ok)
    get "/api/v1/orgs/#{org.key}/conversations/#{alpha_conv.key}", headers: member_h
    expect(response).to have_http_status(:ok)

    # 7. Per-domain overview reflects each domain's slice.
    get "/api/v1/orgs/#{org.key}/admin/overview?domain=#{beta.key}", headers: owner_h
    expect(response.parsed_body["overview"]["pool"]["volume"]).to eq(1)
    get "/api/v1/orgs/#{org.key}/admin/overview", headers: owner_h
    expect(response.parsed_body["overview"]["pool"]["volume"]).to eq(2)

    # 8. Offline sync pull as the member returns only beta + the assigned alpha.
    get "/api/v1/orgs/#{org.key}/sync/pull", headers: member_h
    synced = response.parsed_body.dig("records", "conversations").map { |c| c["subject"] }
    expect(synced).to contain_exactly("beta-thread", "alpha-thread")

    # 9. Limited member: scoping the member to zero domains leaves them with only
    # the threads directly shared with them (the assigned alpha thread).
    patch "/api/v1/orgs/#{org.key}/members/#{member_m.key}",
      params: { all_domains: false, domain_ids: [] }, headers: owner_h
    expect(response).to have_http_status(:ok)
    get "/api/v1/orgs/#{org.key}/conversations", headers: member_h
    expect(response.parsed_body["conversations"].map { |c| c["subject"] }).to contain_exactly("alpha-thread")

    # 10. Granting all domains lets the member see the whole pool again.
    patch "/api/v1/orgs/#{org.key}/members/#{member_m.key}", params: { all_domains: true }, headers: owner_h
    expect(response).to have_http_status(:ok)
    get "/api/v1/orgs/#{org.key}/conversations", headers: member_h
    expect(response.parsed_body["conversations"].map { |c| c["subject"] }).to contain_exactly("alpha-thread", "beta-thread")
  end
end
