require "rails_helper"

# TODO 45.6 — Gmail Pub/Sub webhook verification: shared token + OIDC JWT.
RSpec.describe GmailPushVerifier do
  def fake_request(token: nil, bearer: nil)
    instance_double(ActionDispatch::Request,
      query_parameters: token ? { "token" => token } : {},
      params: {},
      headers: { "Authorization" => bearer && "Bearer #{bearer}" }.compact)
  end

  describe "shared token layer" do
    it "accepts anything when unconfigured" do
      allow(PushConfig).to receive_messages(gmail_verification_token: nil, gmail_push_service_account: nil)
      expect(described_class.verify(fake_request)).to be(true)
    end

    it "rejects a wrong or missing token when configured" do
      allow(PushConfig).to receive_messages(gmail_verification_token: "sekret", gmail_push_service_account: nil)
      expect(described_class.verify(fake_request(token: "wrong"))).to be(false)
      expect(described_class.verify(fake_request)).to be(false)
      expect(described_class.verify(fake_request(token: "sekret"))).to be(true)
    end
  end

  describe "OIDC layer" do
    before do
      allow(PushConfig).to receive_messages(
        gmail_verification_token: nil,
        gmail_push_service_account: "pubsub-push@proj.iam.gserviceaccount.com",
        gmail_push_audience: "https://api.inbox2.com/api/v1/push/gmail"
      )
    end

    it "rejects a request without a bearer token" do
      expect(described_class.verify(fake_request)).to be(false)
    end

    it "accepts a valid token from the expected service account" do
      allow(Google::Auth::IDTokens).to receive(:verify_oidc)
        .with("jwt", aud: "https://api.inbox2.com/api/v1/push/gmail")
        .and_return({ "email" => "pubsub-push@proj.iam.gserviceaccount.com", "email_verified" => true })
      expect(described_class.verify(fake_request(bearer: "jwt"))).to be(true)
    end

    it "rejects a valid token from a different service account" do
      allow(Google::Auth::IDTokens).to receive(:verify_oidc)
        .and_return({ "email" => "attacker@evil.iam.gserviceaccount.com", "email_verified" => true })
      expect(described_class.verify(fake_request(bearer: "jwt"))).to be(false)
    end

    it "rejects a token that fails JWKS verification" do
      allow(Google::Auth::IDTokens).to receive(:verify_oidc)
        .and_raise(Google::Auth::IDTokens::SignatureError, "bad signature")
      expect(described_class.verify(fake_request(bearer: "jwt"))).to be(false)
    end
  end
end
