require "rails_helper"
require "rbnacl"

# docs/E2EE.md Phase I — outbound & drafts sealing. Replies quote sealed
# content, so the stored sent/draft copy is sealed under the domain key and
# the queued MIME under the MTA delivery key. Uses real libsodium keypairs so
# every blob is verified by decrypting it back.
RSpec.describe "E2EE outbound sealing", type: :request do
  let(:owner) { create(:user, username: "outbound_sealer") }
  let(:org) do
    create(:organization, owner: owner, domain: "sealed-out.example").tap do |o|
      o.update!(plan: create(:plan, e2ee: true, tier: Plan::TIER_PAID))
    end
  end
  let(:domain) { org.default_domain }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let!(:sender_box) { create(:mailbox, membership: membership, domain: domain, local_part: "boss") }
  let(:headers) { auth_headers(owner) }

  let(:domain_keypair) { RbNaCl::PrivateKey.generate }
  let(:delivery_keypair) { RbNaCl::PrivateKey.generate }

  before do
    create(:domain_key, domain: domain, version: 1,
      public_key: Base64.strict_encode64(domain_keypair.public_key.to_bytes))
    domain.update_column(:e2ee_enabled, true)

    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("INBOX2_E2EE_FORCE_OFF", anything).and_return("false")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("INBOX2_THREADING_HMAC_KEY").and_return("outbound-spec-key")
    allow(ENV).to receive(:[]).with("INBOX2_MTA_DELIVERY_PUBLIC_KEY")
      .and_return(Base64.strict_encode64(delivery_keypair.public_key.to_bytes))
  end

  def unseal(private_key, blob_b64)
    RbNaCl::Boxes::Sealed.new(private_key.public_key, private_key).open(Base64.strict_decode64(blob_b64))
  end

  def aead_open(dek, nonce_b64, ct_b64, aad)
    RbNaCl::AEAD::XChaCha20Poly1305IETF.new(dek)
      .decrypt(Base64.strict_decode64(nonce_b64), Base64.strict_decode64(ct_b64), aad)
  end

  describe "POST /messages (send) on a sealed domain" do
    def send_message!
      post "/api/v1/orgs/#{org.key}/messages", headers: headers, params: {
        from_address: "boss@sealed-out.example",
        to_address: "partner@external.example",
        subject: "Re: OUTBOUND-SECRET-SUBJECT",
        body_plain: "OUTBOUND-SECRET-BODY quoting the sealed thread",
        body_html: "<p>OUTBOUND-SECRET-BODY quoting the sealed thread</p>"
      }, as: :json
      expect(response).to have_http_status(:created)
      Message.find_by!(key: response.parsed_body["message"]["id"])
    end

    it "stores a sealed row: no plaintext content, recipients kept as wire metadata" do
      message = send_message!

      expect(message.sealed?).to be(true)
      expect(message.subject).to be_nil
      expect(message.body_plain).to be_nil
      expect(message.body_html).to be_nil
      # Outbound recipients stay plaintext — RCPT TO / DSN / suppression need them.
      expect(message.from_address).to eq("boss@sealed-out.example")
      expect(message.to_address).to eq("partner@external.example")
      expect(message.sealed_mime).to be_present
      expect(message.subject_hmac).to be_present

      # Round-trip the at-rest copy with the domain secret (as a client would).
      dek = unseal(domain_keypair, message.sealed_dek)
      header = JSON.parse(aead_open(dek, message.header_nonce, message.header_ciphertext, "#{message.seal_aad}|header"))
      body = JSON.parse(aead_open(dek, message.body_nonce, message.body_ciphertext, "#{message.seal_aad}|body"))
      expect(header["subject"]).to eq("Re: OUTBOUND-SECRET-SUBJECT")
      expect(body["plain"]).to include("OUTBOUND-SECRET-BODY")

      # Conversation preview stays clean.
      expect(message.conversation.reload.snippet).to be_nil
    end

    it "seals the queued MIME to the MTA delivery key (composed before sealing)" do
      message = send_message!

      envelope = JSON.parse(message.sealed_mime)
      dek = unseal(delivery_keypair, envelope["sealed_dek"])
      mime = aead_open(dek, envelope["nonce"], envelope["ciphertext"], message.key)
      expect(mime).to include("OUTBOUND-SECRET-BODY")
      expect(mime).to include("Subject: ")
      expect(mime).to include("To: partner@external.example")
    end

    it "publishes a ciphertext-only NATS payload" do
      message = send_message!
      channel = DeliveryChannel.active_for(org)
      delivery_status = create(:delivery_status, message: message, delivery_channel: channel)

      payload = OutboundMailPublisher.new(message).send(:build_payload, delivery_status, channel)
      json = payload.to_json
      expect(payload[:sealed_mime]).to be_present
      expect(payload[:rfc5322_b64]).to be_nil
      expect(json).not_to include("OUTBOUND-SECRET")
    end

    it "leaves plaintext-domain sends completely unchanged" do
      plain_org = create(:organization, owner: owner, domain: "plain-out.example")
      plain_member = create(:membership, user: owner, organization: plain_org, role: "owner", status: "active")
      create(:mailbox, membership: plain_member, domain: plain_org.default_domain, local_part: "boss")

      post "/api/v1/orgs/#{plain_org.key}/messages", headers: headers, params: {
        from_address: "boss@plain-out.example", to_address: "x@external.example",
        subject: "Plain subject", body_plain: "plain body"
      }, as: :json
      expect(response).to have_http_status(:created)
      message = Message.find_by!(key: response.parsed_body["message"]["id"])
      expect(message.sealed?).to be(false)
      expect(message.subject).to eq("Plain subject")
      expect(message.sealed_mime).to be_nil
    end
  end

  describe "drafts on a sealed domain" do
    it "seals on create and re-seals with fresh content on autosave" do
      post "/api/v1/orgs/#{org.key}/drafts", headers: headers, params: {
        from_address: "boss@sealed-out.example", to_address: "partner@external.example",
        subject: "DRAFT-SECRET v1", body_plain: "draft body v1"
      }, as: :json
      expect(response).to have_http_status(:created)
      draft = Message.find_by!(key: response.parsed_body["draft"]["id"])

      expect(draft.sealed?).to be(true)
      expect(draft.subject).to be_nil
      expect(draft.body_plain).to be_nil

      patch "/api/v1/orgs/#{org.key}/drafts/#{draft.key}", headers: headers, params: {
        from_address: "boss@sealed-out.example",
        subject: "DRAFT-SECRET v2", body_plain: "draft body v2"
      }, as: :json
      expect(response).to have_http_status(:ok)

      draft.reload
      dek = unseal(domain_keypair, draft.sealed_dek)
      header = JSON.parse(aead_open(dek, draft.header_nonce, draft.header_ciphertext, "#{draft.seal_aad}|header"))
      body = JSON.parse(aead_open(dek, draft.body_nonce, draft.body_ciphertext, "#{draft.seal_aad}|body"))
      expect(header["subject"]).to eq("DRAFT-SECRET v2")
      expect(body["plain"]).to eq("draft body v2")
    end
  end

  describe "BYO-ESP guard" do
    it "fails fast instead of handing an empty message to a custom provider" do
      message = nil
      post "/api/v1/orgs/#{org.key}/messages", headers: headers, params: {
        from_address: "boss@sealed-out.example", to_address: "x@external.example",
        subject: "s", body_plain: "b"
      }, as: :json
      message = Message.find_by!(key: response.parsed_body["message"]["id"])

      channel = create(:delivery_channel, organization: org, kind: DeliveryChannel::KIND_SENDGRID,
        is_default: true, config: { "api_key" => "sg" })
      allow(DeliveryChannel).to receive(:active_for).and_return(channel)

      status = OutboundMailPublisher.new(message).publish.sole
      expect(status.status).to eq(DeliveryStatus::STATUS_FAILED)
      expect(status.dsn_diagnostic).to include("sealed")
    end
  end
end
