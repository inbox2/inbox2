require "rails_helper"

# End-to-end offboarding consequences — the destructive console flow, followed
# past the endpoint into what actually happens to mail and access afterwards:
# a bounce-retired address rejects new mail at ingest; a reroute-retired
# address keeps receiving and the chosen successor gains access even outside
# their domain scope; the departed member's session loses the org entirely.
RSpec.describe "E2E: offboarding consequences", type: :request do
  def login(username, password = "password123")
    post "/api/v1/auth/login", params: { username: username, password: password }
    expect(response).to have_http_status(:ok)
    { "Authorization" => "Bearer #{response.parsed_body['token']}" }
  end

  # Land a real inbound message for an explicit recipient through the pipeline.
  def inbound_to(address, domain:, subject:)
    InboundMailProcessor.new({
      "envelope" => { "mail_from" => "ext@world.test", "rcpt_to" => [address], "client_ip" => "203.0.113.9" },
      "headers" => { "from" => "Ext <ext@world.test>", "to" => address, "subject" => subject,
                     "content_type" => "text/plain", "message_id" => "<#{SecureRandom.hex(4)}@world.test>" },
      "body" => { "plain" => "hello", "html" => "" },
      "attachments" => [],
      "authentication" => { "dmarc" => { "result" => "pass", "policy" => "none" } },
      "raw_message_b64" => "",
      "domain" => domain
    }).process
  end

  let!(:owner) { create(:user, username: "off_owner") }
  let!(:org) { create(:organization, owner: owner, domain: "corp.test") }
  let!(:owner_m) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let!(:sub) { create(:subscription, organization: org, plan: Plan.max) }
  let!(:shop) { create(:domain, organization: org, name: "shop.test") }

  let!(:leaver) { create(:user, username: "off_leaver") }
  let!(:leaver_m) { create(:membership, user: leaver, organization: org, role: "member", status: "active") }
  let!(:leaver_mbx) { Mailbox.create!(membership: leaver_m, domain: org.default_domain, local_part: "leaver") }

  # The successor is scoped to the OTHER domain, so only the reroute grant can
  # expose corp.test threads to them.
  let!(:keeper) { create(:user, username: "off_keeper") }
  let!(:keeper_m) do
    m = build(:membership, user: keeper, organization: org, role: "member", status: "active", all_domains: false)
    m.domains = [shop]
    m.save!
    m
  end

  before { org.reload }

  it "reroute journey: successor receives the retired address's mail across domain scope" do
    owner_h = login("off_owner")
    keeper_h = login("off_keeper")

    # Baseline: mail to the leaver lands, keeper (scoped to shop.test) can't see it.
    inbound_to("leaver@corp.test", domain: "corp.test", subject: "Before offboard")
    get "/api/v1/orgs/#{org.key}/conversations", headers: keeper_h
    expect(response.parsed_body["conversations"]).to be_empty

    # Offboard with reroute → keeper.
    delete "/api/v1/admin/users/#{leaver.key}",
      params: { data_handling: "archive", alias_handling: "reroute", reroute_target_id: keeper_m.key },
      headers: owner_h, as: :json
    expect(response).to have_http_status(:no_content)
    expect(org.memberships.where(user: leaver)).not_to exist
    expect(org.mailbox_aliases.find_by(local_part: "leaver").mode).to eq(MailboxAlias::MODE_REROUTE)

    # The departed member's session has lost the org entirely (E3: 404).
    leaver_h = login("off_leaver")
    get "/api/v1/account/organizations", headers: leaver_h
    expect(response.parsed_body["organizations"]).to be_empty
    get "/api/v1/orgs/#{org.key}/conversations", headers: leaver_h
    expect(response).to have_http_status(:not_found)

    # New mail to the retired address is ACCEPTED and the reroute grant pierces
    # the successor's domain scope.
    result = inbound_to("leaver@corp.test", domain: "corp.test", subject: "After offboard")
    expect(result[:conversation]).to be_present
    get "/api/v1/orgs/#{org.key}/conversations", headers: keeper_h
    subjects = response.parsed_body["conversations"].map { |c| c["subject"] }
    expect(subjects).to include("After offboard")
    # Archive handling retained the old thread for the org (owner still sees it).
    get "/api/v1/orgs/#{org.key}/conversations", headers: owner_h
    expect(response.parsed_body["conversations"].map { |c| c["subject"] }).to include("Before offboard")
  end

  it "bounce journey: the retired address rejects new mail at ingest" do
    owner_h = login("off_owner")

    delete "/api/v1/admin/users/#{leaver.key}",
      params: { data_handling: "archive", alias_handling: "bounce" },
      headers: owner_h, as: :json
    expect(response).to have_http_status(:no_content)

    expect {
      result = inbound_to("leaver@corp.test", domain: "corp.test", subject: "Into the void")
      expect(result[:bounced]).to be(true)
    }.not_to change(Conversation, :count)
  end
end
