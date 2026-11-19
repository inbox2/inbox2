require "rails_helper"

# docs/E2EE.md Phase F — read path dual-mode + the recovery email backup.
RSpec.describe "E2EE read path", type: :request do
  include ActiveJob::TestHelper

  let(:owner) { create(:user, username: "readpath") }
  let(:org) { create(:organization, owner: owner, domain: "readpath.example") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  describe "MessageSerializer" do
    it "serves ciphertext blobs + null plaintext for sealed, plaintext untouched otherwise" do
      conv = create(:conversation, organization: org, subject: nil, from_address: nil, snippet: nil)
      sealed = create(:message, conversation: conv, organization: org,
        encryption_scheme: Message::ENCRYPTION_SCHEME_SEALED_BOX_V1,
        from_address: nil, subject: nil, body_plain: nil, body_html: nil, message_id_header: nil,
        domain_key_version: 2, seal_aad: "9|2|abc", sealed_dek: "DEK", msgid_hmac: "abc",
        body_nonce: "BN", body_ciphertext: "BC", header_nonce: "HN", header_ciphertext: "HC")
      plain = create(:message, conversation: conv, organization: org)

      sealed_json = MessageSerializer.new(sealed).to_h
      expect(sealed_json["encryption_scheme"]).to eq("sealed_box_v1")
      expect(sealed_json["subject"]).to be_nil
      expect(sealed_json["body_plain"]).to be_nil
      expect(sealed_json["from_address"]).to be_nil
      expect(sealed_json["sealed"]).to eq(
        domain_key_version: 2, aad: "9|2|abc", sealed_dek: "DEK",
        body_nonce: "BN", body_ciphertext: "BC", header_nonce: "HN", header_ciphertext: "HC"
      )

      plain_json = MessageSerializer.new(plain).to_h
      expect(plain_json["sealed"]).to be_nil
      expect(plain_json["body_plain"]).to be_present
    end

    it "names the scheme in a v2 bundle and counts it as sealed" do
      conv = create(:conversation, organization: org, subject: nil, from_address: nil, snippet: nil)
      sealed = create(:message, conversation: conv, organization: org,
        encryption_scheme: Message::ENCRYPTION_SCHEME_SEALED_BOX_V2,
        from_address: nil, subject: nil, body_plain: nil, body_html: nil, message_id_header: nil,
        domain_key_version: 2, seal_aad: "9|2|abc", sealed_dek: "DEK", msgid_hmac: "abc",
        body_nonce: "BN", body_ciphertext: "BC", header_nonce: "HN", header_ciphertext: "HC")

      expect(sealed).to be_sealed
      expect(MessageSerializer.new(sealed).to_h["sealed"][:scheme]).to eq("sealed_box_v2")
    end
  end

  describe "POST /api/v1/user-key/recovery-email" do
    it "queues the Messy send with the opaque blob embedded" do
      post "/api/v1/user-key/recovery-email", headers: headers,
        params: { blob: "T1BBUVVFLUJMT0I=" }, as: :json

      expect(response).to have_http_status(:accepted)
      job = enqueued_jobs.find { |j| j["job_class"] == "MessyTriggerJob" }
      expect(job).to be_present
      args = job["arguments"].to_json
      expect(args).to include("T1BBUVVFLUJMT0I=")
      expect(args).to include(owner.billing_email)
    end

    it "rejects an oversized blob" do
      post "/api/v1/user-key/recovery-email", headers: headers,
        params: { blob: "x" * (65 * 1024) }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects a blank blob" do
      post "/api/v1/user-key/recovery-email", headers: headers, params: {}, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
