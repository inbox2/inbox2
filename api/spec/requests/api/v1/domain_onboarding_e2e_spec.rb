require "rails_helper"

# End-to-end domain onboarding — THE console funnel every new customer walks
# (spec 2.2/2.3, A3, S2): signup → create the org+domain → read the DNS
# records → verify → first real inbound message → receiving_mail promotion →
# the mail is sitting in the pool. Driven entirely over HTTP with the session
# from signup, exactly like the console does it.
RSpec.describe "E2E: domain onboarding", type: :request do
  before { allow_any_instance_of(DnsResolver).to receive(:ns).and_return([]) }

  # Land a real inbound email through the actual pipeline (same shape the MX
  # publishes to NATS).
  def inbound_to(domain_name, subject:)
    InboundMailProcessor.new({
      "envelope" => { "mail_from" => "customer@world.test", "rcpt_to" => ["hello@#{domain_name}"], "client_ip" => "203.0.113.5" },
      "headers" => { "from" => "Customer <customer@world.test>", "to" => "hello@#{domain_name}", "subject" => subject,
                     "content_type" => "text/plain", "message_id" => "<#{SecureRandom.hex(4)}@world.test>" },
      "body" => { "plain" => "hi, first mail!", "html" => "" },
      "attachments" => [],
      "authentication" => { "dmarc" => { "result" => "pass", "policy" => "none" } },
      "raw_message_b64" => ""
    }).process
  end

  it "walks signup → domain → DNS verify → first inbound → receiving_mail → pool" do
    # 1. Fresh signup, console-style.
    post "/api/v1/auth/signup",
      params: { username: "founder", password: "a-long-password-4",
                password_confirmation: "a-long-password-4", billing_email: "founder@external.com" }
    expect(response).to have_http_status(:created)
    headers = { "Authorization" => "Bearer #{response.parsed_body['token']}" }

    # 2. Create the org + first domain; it starts pending DNS on the Free plan.
    post "/api/v1/orgs", params: { name: "Startup", domain: "startup.test" }, headers: headers
    expect(response).to have_http_status(:created)
    org_key = response.parsed_body["organization"]["id"]
    org = Organization.find_by!(key: org_key)
    domain = org.default_domain
    expect(domain.status).to eq(Domain::STATUS_PENDING_DNS)

    # 3. The setup screen's DNS records: MX + SPF + DMARC + DKIM, all pending.
    get "/api/v1/orgs/#{org_key}/domains/#{domain.key}/dns", headers: headers
    expect(response).to have_http_status(:ok)
    records = response.parsed_body["records"]
    expect(records.map { |r| r["type"] }).to include("MX", "TXT", "CNAME")
    expect(records.map { |r| r["status"] }).to all(eq("pending_dns"))

    # 4. Verify fails while DNS isn't set up — the domain stays pending.
    allow(DnsChecker).to receive(:new).and_return(
      instance_double(DnsChecker, call: { mx_ok: false, all_ok: false, checks: { mx: false, spf: false, dmarc: false, dkim: false } })
    )
    post "/api/v1/orgs/#{org_key}/domains/#{domain.key}/dns/verify", headers: headers
    expect(response.parsed_body["verified"]).to be(false)
    expect(domain.reload.status).to eq(Domain::STATUS_PENDING_DNS)

    # 5. Customer fixes DNS; verify flips the domain to verified.
    allow(DnsChecker).to receive(:new).and_return(
      instance_double(DnsChecker, call: { mx_ok: true, all_ok: true, checks: { mx: true, spf: true, dmarc: true, dkim: true } })
    )
    post "/api/v1/orgs/#{org_key}/domains/#{domain.key}/dns/verify", headers: headers
    expect(response.parsed_body["verified"]).to be(true)
    expect(domain.reload.status).to eq(Domain::STATUS_VERIFIED)

    # 6. First real message arrives → one-way promotion to receiving_mail.
    inbound_to("startup.test", subject: "Our first customer email")
    expect(domain.reload.status).to eq(Domain::STATUS_RECEIVING_MAIL)

    # 7. …and the founder sees it in the pool.
    get "/api/v1/orgs/#{org_key}/conversations", headers: headers
    subjects = response.parsed_body["conversations"].map { |c| c["subject"] }
    expect(subjects).to include("Our first customer email")

    # 8. A later DNS wobble never demotes a receiving domain (DnsCheckJob
    # leaves receiving_mail alone) — re-verifying reports but doesn't regress.
    inbound_to("startup.test", subject: "Second mail")
    expect(domain.reload.status).to eq(Domain::STATUS_RECEIVING_MAIL)
  end
end
