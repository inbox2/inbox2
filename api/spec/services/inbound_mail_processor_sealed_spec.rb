require "rails_helper"

# docs/E2EE.md Phase D — the sealed branch of the inbound consumer. Payloads
# mirror what the Go MX publishes (queue.InboundMessage with Sealed set and all
# plaintext fields zeroed).
RSpec.describe InboundMailProcessor, "sealed mail" do
  let(:owner) { create(:user, username: "sealed_owner") }
  let(:org) { create(:organization, owner: owner, domain: "sealed.example") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:domain) { org.default_domain }

  HMAC_KEY = "spec-threading-key"

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("INBOX2_THREADING_HMAC_KEY").and_return(HMAC_KEY)
  end

  def hmac(value) = OpenSSL::HMAC.hexdigest("SHA256", HMAC_KEY, value)

  def b64(str) = Base64.strict_encode64(str)

  def sealed_payload(msgid: "<sealed-#{SecureRandom.hex(4)}@ext.example>", refs: [], subject_hmac: nil, spam: {}, attachments: [])
    {
      "version" => 1,
      "received_at" => Time.current.iso8601,
      "envelope" => { "rcpt_to" => ["team@sealed.example"] },
      "headers" => {},
      "body" => {},
      "attachments" => [],
      "authentication" => {
        "spf" => { "result" => "pass" }, "dkim" => { "result" => "pass" },
        "dmarc" => { "result" => "pass", "policy" => "none" }
      },
      "raw_size_bytes" => 2048,
      "encryption_scheme" => "sealed_box_v1",
      "sealed" => {
        "domain_id" => domain.id,
        "key_version" => 1,
        "sealed_dek" => b64("sealed-dek-blob"),
        "body_nonce" => b64("nonce-b"),
        "body_ciphertext" => b64("body-ciphertext"),
        "header_nonce" => b64("nonce-h"),
        "header_ciphertext" => b64("header-ciphertext"),
        "msgid_hmac" => hmac(msgid),
        "refs_hmac" => refs,
        "subject_hmac" => subject_hmac,
        "attachments" => attachments
      }.merge(spam)
    }
  end

  it "stores a ciphertext-only row: no plaintext content, sender, or preview" do
    result = described_class.new(sealed_payload(subject_hmac: hmac("secret subject"))).process
    msg = result[:message]
    conv = result[:conversation]

    expect(msg.sealed?).to be(true)
    expect(msg.body_plain).to be_nil
    expect(msg.body_html).to be_nil
    expect(msg.subject).to be_nil
    expect(msg.from_address).to be_nil
    expect(msg.message_id_header).to be_nil
    expect(msg.sealed_dek).to be_present
    expect(msg.body_ciphertext).to be_present
    expect(msg.header_ciphertext).to be_present
    expect(msg.domain_key_version).to eq(1)

    expect(conv.subject).to be_nil
    expect(conv.snippet).to be_nil
    expect(conv.from_address).to be_nil
    expect(conv.to_address).to be_nil
    expect(conv.search_vector).to be_nil
    expect(conv.subject_hmac).to eq(hmac("secret subject"))
  end

  it "dedupes redeliveries via msgid_hmac" do
    payload = sealed_payload
    described_class.new(payload).process
    expect { expect(described_class.new(payload).process).to eq({ duplicate: true }) }
      .not_to change(Message, :count)
  end

  it "threads a sealed reply onto a sealed original via refs_hmac" do
    original = sealed_payload(msgid: "<root@ext.example>")
    conv = described_class.new(original).process[:conversation]

    reply = sealed_payload(refs: [hmac("<root@ext.example>")])
    expect(described_class.new(reply).process[:conversation]).to eq(conv)
  end

  it "threads a sealed reply onto a PLAINTEXT original (mixed-mode)" do
    plain = {
      "version" => 1, "received_at" => Time.current.iso8601,
      "envelope" => { "mail_from" => "alice@ext.example", "rcpt_to" => ["team@sealed.example"],
                      "client_ip" => "203.0.113.9", "helo_domain" => "mail.ext.example" },
      "headers" => { "message_id" => "<plain-root@ext.example>", "from" => "alice@ext.example",
                     "to" => "team@sealed.example", "subject" => "Quarterly numbers",
                     "content_type" => "text/plain" },
      "body" => { "plain" => "before sealing was enabled", "html" => "" },
      "attachments" => [],
      "authentication" => { "dmarc" => { "result" => "pass", "policy" => "none" } },
      "raw_size_bytes" => 512, "raw_message_b64" => ""
    }
    conv = described_class.new(plain).process[:conversation]

    reply = sealed_payload(refs: [hmac("<plain-root@ext.example>")])
    expect(described_class.new(reply).process[:conversation]).to eq(conv)
  end

  it "threads a PLAINTEXT reply onto a sealed original (mixed-mode, via msgid_hmac)" do
    sealed_conv = described_class.new(sealed_payload(msgid: "<sealed-root@ext.example>")).process[:conversation]

    plain_reply = {
      "version" => 1, "received_at" => Time.current.iso8601,
      "envelope" => { "mail_from" => "bob@ext.example", "rcpt_to" => ["team@sealed.example"],
                      "client_ip" => "203.0.113.9", "helo_domain" => "mail.ext.example" },
      "headers" => { "message_id" => "<plain-reply@ext.example>", "in_reply_to" => "<sealed-root@ext.example>",
                     "from" => "bob@ext.example", "to" => "team@sealed.example",
                     "subject" => "Re: whatever", "content_type" => "text/plain" },
      "body" => { "plain" => "replying in the clear", "html" => "" },
      "attachments" => [],
      "authentication" => { "dmarc" => { "result" => "pass", "policy" => "none" } },
      "raw_size_bytes" => 512, "raw_message_b64" => ""
    }
    expect(described_class.new(plain_reply).process[:conversation]).to eq(sealed_conv)
  end

  it "groups sealed threads by subject_hmac fallback" do
    a = described_class.new(sealed_payload(subject_hmac: hmac("project atlas"))).process[:conversation]
    b = described_class.new(sealed_payload(subject_hmac: hmac("project atlas"))).process[:conversation]
    expect(b).to eq(a)
  end

  it "never threads into a plaintext thread that shares the subject_hmac (another member's mail)" do
    plain = create(:conversation, organization: org, subject: "project atlas", subject_hmac: hmac("project atlas"),
                   from_address: "someone@else.test", to_address: "colleague@#{org.default_domain.name}")
    sealed = described_class.new(sealed_payload(subject_hmac: hmac("project atlas"))).process[:conversation]
    expect(sealed).not_to eq(plain)
  end

  describe "a teammate's personal mailbox stays theirs on a sealed domain" do
    let(:badr) { create(:membership, organization: org, role: "member", status: "active") }
    let!(:box) { create(:mailbox, membership: badr, domain: domain, local_part: "badr") }

    def to_badr(**opts)
      sealed_payload(**opts).tap { |pl| pl["envelope"]["rcpt_to"] = ["badr@sealed.example"] }
    end

    it "stamps the thread with its member and hides it from the owner, admins and org-wide readers" do
      conv = described_class.new(to_badr).process[:conversation]
      expect(conv).to have_attributes(personal_membership_id: badr.id, to_address: nil)
      expect(org.conversations.visible_to(membership)).not_to include(conv)
      expect(org.conversations.visible_to(badr)).to include(conv)
      expect(org.conversations.org_readable).not_to include(conv)
    end

    it "keeps shared-address sealed mail in the pool" do
      conv = described_class.new(sealed_payload).process[:conversation]
      expect(conv.personal_membership_id).to be_nil
      expect(org.conversations.visible_to(membership)).to include(conv)
    end

    it "never joins a shared sealed thread by subject_hmac" do
      shared = described_class.new(sealed_payload(subject_hmac: hmac("project atlas"))).process[:conversation]
      personal = described_class.new(to_badr(subject_hmac: hmac("project atlas"))).process[:conversation]
      expect(personal).not_to eq(shared)
    end
  end

  it "never enqueues ClassifySpaceJob or calls Rspamd for sealed mail" do
    org.update!(plan: create(:plan, e2ee: true, ai_triage: true, spam_filter: true))
    allow(SpaceClassifier).to receive(:enabled?).and_return(true)
    expect(RspamdClient).not_to receive(:new)

    expect { described_class.new(sealed_payload).process }
      .not_to have_enqueued_job(ClassifySpaceJob)
  end

  it "routes spam by the MX-provided verdict metadata" do
    payload = sealed_payload(spam: { "spam_score" => 9.5, "spam_action" => "reject", "spam_symbols" => ["BAYES_SPAM"] })
    result = described_class.new(payload).process

    expect(result[:message].spam_score).to eq(9.5)
    expect(result[:message].spam_action).to eq("reject")
    expect(result[:conversation].reload.status).to eq(Conversation::STATUS_SPAM)
  end

  it "stores sealed attachment metadata without plaintext filename or content text" do
    payload = sealed_payload(attachments: [{
      "index" => 0, "object_key" => "org_x/sealed/2026/07/03/aa/att-0",
      "sealed_filename" => b64("name-ct"), "filename_nonce" => b64("nonce-n"),
      "content_nonce" => b64("nonce-c"), "size_bytes" => 999,
      "content_type" => "application/pdf", "is_inline" => false
    }])
    msg = described_class.new(payload).process[:message]

    att = msg.attachments.sole
    expect(att.filename).to be_nil
    expect(att.sealed_filename).to be_present
    expect(att.filename_nonce).to be_present
    expect(att.content_text).to be_nil
    expect(att.search_vector).to be_nil
    expect(att.storage_key).to eq("org_x/sealed/2026/07/03/aa/att-0")
    expect(att.searchable?).to be(false)
  end

  it "passes the MX notification preview to the push sender (default-on domains)" do
    payload = sealed_payload
    payload["sealed"]["notification_preview"] = { "from" => "Bob <bob@ext.example>", "subject" => "Preview subject" }
    allow(MobilePushSender).to receive(:org_recipients).and_return([owner])
    expect(MobilePushSender).to receive(:new_message)
      .with(owner, hash_including(sealed_preview: { "from" => "Bob <bob@ext.example>", "subject" => "Preview subject" }))

    described_class.new(payload).process
  end

  it "passes no preview when the MX did not ship one (default)" do
    allow(MobilePushSender).to receive(:org_recipients).and_return([owner])
    expect(MobilePushSender).to receive(:new_message).with(owner, hash_including(sealed_preview: nil))

    described_class.new(sealed_payload).process
  end

  it "stores threading HMACs on plaintext rows too (uniform grouping)" do
    plain = {
      "version" => 1, "received_at" => Time.current.iso8601,
      "envelope" => { "mail_from" => "carol@ext.example", "rcpt_to" => ["team@sealed.example"],
                      "client_ip" => "203.0.113.9", "helo_domain" => "m.ext.example" },
      "headers" => { "message_id" => "<hmac-check@ext.example>", "in_reply_to" => "<parent@ext.example>",
                     "references" => "<gp@ext.example> <parent@ext.example>",
                     "from" => "carol@ext.example", "to" => "team@sealed.example",
                     "subject" => "Re: Budget planning", "content_type" => "text/plain" },
      "body" => { "plain" => "hi", "html" => "" },
      "attachments" => [],
      "authentication" => { "dmarc" => { "result" => "pass", "policy" => "none" } },
      "raw_size_bytes" => 100, "raw_message_b64" => ""
    }
    result = described_class.new(plain).process
    msg = result[:message]

    expect(msg.msgid_hmac).to eq(hmac("<hmac-check@ext.example>"))
    expect(msg.refs_hmac).to eq([hmac("<gp@ext.example>"), hmac("<parent@ext.example>")])
    expect(msg.subject_hmac).to eq(hmac("Budget planning"))
    expect(result[:conversation].subject_hmac).to eq(hmac("Budget planning"))
  end
end
