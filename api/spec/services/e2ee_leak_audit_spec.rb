require "rails_helper"
require "rbnacl"

# docs/E2EE.md Phase H — the automated plaintext-scan test. A marker token is
# sealed through both directions of the pipeline with REAL crypto, then every
# durable Rails surface is scanned for it: model columns, enqueued job
# arguments (what lands in solid_queue_jobs.arguments), and log output.
# The memory triage stream is deliberately excluded — that is the accepted
# transient surface. The Go-side equivalents (durable NATS payload, MX logs,
# spooled attachment bytes) are pinned by mta/internal/smtpd/sealer_test.go.
RSpec.describe "E2EE leak audit (Phase H)", type: :request do
  include ActiveJob::TestHelper

  MARKER = "LEAKMARKER7263".freeze

  let(:owner) { create(:user, username: "leak_auditor") }
  let(:org) do
    create(:organization, owner: owner, domain: "leakaudit.example").tap do |o|
      o.update!(plan: create(:plan, e2ee: true, tier: Plan::TIER_PAID))
    end
  end
  let(:domain) { org.default_domain }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let!(:sender_box) { create(:mailbox, membership: membership, domain: org.default_domain, local_part: "boss") }
  let(:domain_keypair) { RbNaCl::PrivateKey.generate }
  let(:delivery_keypair) { RbNaCl::PrivateKey.generate }

  before do
    create(:domain_key, domain: domain, version: 1,
      public_key: Base64.strict_encode64(domain_keypair.public_key.to_bytes))
    domain.update_column(:e2ee_enabled, true)

    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("INBOX2_E2EE_FORCE_OFF", anything).and_return("false")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("INBOX2_THREADING_HMAC_KEY").and_return("leak-audit-key")
    allow(ENV).to receive(:[]).with("INBOX2_MTA_DELIVERY_PUBLIC_KEY")
      .and_return(Base64.strict_encode64(delivery_keypair.public_key.to_bytes))
    allow(MobilePushConfig).to receive(:configured?).and_return(true)
  end

  # Captures everything written to Rails.logger during the block.
  def capture_logs
    io = StringIO.new
    old = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = old
  end

  # Scans one AR record's raw column values for the marker. Ciphertext columns
  # are included on purpose: base64 of an AEAD can never contain the marker,
  # so a hit means plaintext leaked into a blob column.
  def scan_record!(record, surface)
    record.reload.attributes.each do |column, value|
      next if value.nil?
      expect(value.to_s).not_to include(MARKER), "#{surface}: #{record.class.name}##{column} leaks the marker"
    end
  end

  def sealed_inbound_payload
    hmac_key = "leak-audit-key"
    msgid = "<#{MARKER.downcase}-safe@ext.example>" # marker NOT in the message id
    msgid_hmac = OpenSSL::HMAC.hexdigest("SHA256", hmac_key, "<leak-1@ext.example>")
    aad = "#{domain.id}|1|#{msgid_hmac}"

    dek = RbNaCl::Random.random_bytes(32)
    aead = RbNaCl::AEAD::XChaCha20Poly1305IETF.new(dek)
    enc = lambda do |plaintext|
      nonce = RbNaCl::Random.random_bytes(aead.nonce_bytes)
      [Base64.strict_encode64(nonce), Base64.strict_encode64(aead.encrypt(nonce, plaintext, aad))]
    end

    header_nonce, header_ct = enc.call({ subject: "Subject #{MARKER}", from: "Sender #{MARKER} <s@ext.example>",
                                          to: "team@leakaudit.example", snippet: "snippet #{MARKER}" }.to_json)
    body_nonce, body_ct = enc.call({ plain: "body #{MARKER}", html: "<p>body #{MARKER}</p>" }.to_json)
    sealed_dek = RbNaCl::Boxes::Sealed.from_public_key(domain_keypair.public_key).box(dek)

    {
      "version" => 1, "received_at" => Time.current.iso8601,
      "envelope" => { "rcpt_to" => ["team@leakaudit.example"] },
      "headers" => {}, "body" => {}, "attachments" => [],
      "authentication" => { "dmarc" => { "result" => "pass", "policy" => "none" } },
      "raw_size_bytes" => 4096,
      "encryption_scheme" => "sealed_box_v1",
      "sealed" => {
        "domain_id" => domain.id, "key_version" => 1, "aad" => aad,
        "sealed_dek" => Base64.strict_encode64(sealed_dek),
        "body_nonce" => body_nonce, "body_ciphertext" => body_ct,
        "header_nonce" => header_nonce, "header_ciphertext" => header_ct,
        "msgid_hmac" => msgid_hmac, "refs_hmac" => [], "subject_hmac" => nil,
        "attachments" => []
      }
    }
  end

  it "a sealed INBOUND message leaves no marker in columns, job args, or logs" do
    result = nil
    logs = capture_logs do
      result = InboundMailProcessor.new(sealed_inbound_payload).process
    end

    message = result[:message]
    scan_record!(message, "inbound")
    scan_record!(message.conversation, "inbound")

    args = enqueued_jobs.to_json
    expect(args).not_to include(MARKER), "enqueued job arguments leak the marker"
    expect(logs).not_to include(MARKER), "Rails logs leak the marker"

    # And the client can still get it back — the marker exists ONLY behind the seal.
    dek = RbNaCl::Boxes::Sealed.new(domain_keypair.public_key, domain_keypair)
      .open(Base64.strict_decode64(message.sealed_dek))
    body = RbNaCl::AEAD::XChaCha20Poly1305IETF.new(dek).decrypt(
      Base64.strict_decode64(message.body_nonce),
      Base64.strict_decode64(message.body_ciphertext),
      message.seal_aad
    )
    expect(body).to include(MARKER)
  end

  it "a sealed OUTBOUND send leaves no marker in columns, job args, payload, or logs" do
    message = nil
    logs = capture_logs do
      post "/api/v1/orgs/#{org.key}/messages", headers: auth_headers(owner), params: {
        from_address: "boss@leakaudit.example",
        to_address: "partner@external.example",
        subject: "Subject #{MARKER}",
        body_plain: "body #{MARKER}",
        body_html: "<p>body #{MARKER}</p>"
      }, as: :json
      expect(response).to have_http_status(:created)
      message = Message.find_by!(key: response.parsed_body["message"]["id"])
    end

    scan_record!(message, "outbound")
    scan_record!(message.conversation, "outbound")
    expect(enqueued_jobs.to_json).not_to include(MARKER)
    expect(logs).not_to include(MARKER)

    # The durable NATS payload for delivery is ciphertext-only too.
    channel = DeliveryChannel.active_for(org)
    ds = create(:delivery_status, message: message, delivery_channel: channel)
    payload = OutboundMailPublisher.new(message).send(:build_payload, ds, channel)
    expect(payload.to_json).not_to include(MARKER)
  end

  it "a sealed DRAFT autosave leaves no marker in columns or logs" do
    draft = nil
    logs = capture_logs do
      post "/api/v1/orgs/#{org.key}/drafts", headers: auth_headers(owner), params: {
        from_address: "boss@leakaudit.example", to_address: "partner@external.example",
        subject: "Draft #{MARKER}", body_plain: "draft body #{MARKER}"
      }, as: :json
      expect(response).to have_http_status(:created)
      draft = Message.find_by!(key: response.parsed_body["draft"]["id"])
    end

    scan_record!(draft, "draft")
    scan_record!(draft.conversation, "draft")
    expect(logs).not_to include(MARKER)
  end

  it "notification preview (default ON) leaks exactly from+subject to push args — never the body" do
    create(:push_device, user: owner)
    allow_any_instance_of(User).to receive(:push_enabled?).and_return(true)
    # Who rings is the folder bells' business (AddressFolders); this is about what the push carries.
    allow(MobilePushSender).to receive(:conversation_recipients).and_return([owner])

    payload = sealed_inbound_payload
    payload["sealed"]["notification_preview"] = { "from" => "Sender S-#{MARKER}", "subject" => "Subject S-#{MARKER}" }

    result = InboundMailProcessor.new(payload).process
    message = result[:message]

    # Row + conversation still fully sealed — the preview is never stored.
    scan_record!(message, "preview-inbound")
    scan_record!(message.conversation, "preview-inbound")

    # The accepted leak: from/subject in the push job args...
    push_jobs = enqueued_jobs.select { |j| j["job_class"] == "MobilePushDeliveryJob" }
    expect(push_jobs).to be_present
    args = push_jobs.to_json
    expect(args).to include("S-#{MARKER}")
    # ...and STRICTLY nothing else: the body marker must not appear anywhere.
    expect(args).not_to include("body #{MARKER}")
  end

  it "the API response for a sealed conversation carries no marker" do
    result = InboundMailProcessor.new(sealed_inbound_payload).process
    conv = result[:conversation]

    get "/api/v1/orgs/#{org.key}/conversations/#{conv.key}", headers: auth_headers(owner)
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(MARKER)
  end
end
