require "rails_helper"

RSpec.describe OauthVerifier do
  let(:google) { OauthIdentity::PROVIDER_GOOGLE }
  let(:microsoft) { OauthIdentity::PROVIDER_MICROSOFT }

  # Build an unsigned JWT with the given payload (we only read claims, never the
  # signature — identity itself is still re-fetched from the provider).
  def jwt(payload)
    enc = ->(h) { Base64.urlsafe_encode64(JSON.generate(h)).delete("=") }
    "#{enc.call({ alg: 'none' })}.#{enc.call(payload)}.sig"
  end

  def stub_env(pairs)
    allow(ENV).to receive(:[]).and_call_original
    pairs.each { |k, v| allow(ENV).to receive(:[]).with(k).and_return(v) }
  end

  describe ".audience_ok? — Google" do
    before { stub_env("GOOGLE_CLIENT_ID" => "our-client.apps.googleusercontent.com") }

    it "accepts a token whose aud is our client" do
      allow(described_class).to receive(:google_tokeninfo)
        .and_return({ "aud" => "our-client.apps.googleusercontent.com" })
      expect(described_class.audience_ok?(google, "tok")).to be(true)
    end

    it "accepts a token whose azp is our client" do
      allow(described_class).to receive(:google_tokeninfo)
        .and_return({ "aud" => "something-else", "azp" => "our-client.apps.googleusercontent.com" })
      expect(described_class.audience_ok?(google, "tok")).to be(true)
    end

    it "rejects a token minted for another app (confused-deputy takeover)" do
      allow(described_class).to receive(:google_tokeninfo)
        .and_return({ "aud" => "attacker-app.apps.googleusercontent.com" })
      expect(described_class.audience_ok?(google, "tok")).to be(false)
    end

    it "rejects when tokeninfo cannot be fetched" do
      allow(described_class).to receive(:google_tokeninfo).and_return(nil)
      expect(described_class.audience_ok?(google, "tok")).to be(false)
    end
  end

  describe ".audience_ok? — Microsoft" do
    before { stub_env("MICROSOFT_CLIENT_ID" => "ms-client-guid") }

    it "accepts a Graph JWT whose appid is our client" do
      expect(described_class.audience_ok?(microsoft, jwt("appid" => "ms-client-guid"))).to be(true)
    end

    it "accepts a Graph JWT whose azp is our client" do
      expect(described_class.audience_ok?(microsoft, jwt("azp" => "ms-client-guid"))).to be(true)
    end

    it "rejects a Graph JWT from another app" do
      expect(described_class.audience_ok?(microsoft, jwt("appid" => "someone-else"))).to be(false)
    end

    it "rejects an unparseable token" do
      expect(described_class.audience_ok?(microsoft, "not-a-jwt")).to be(false)
    end
  end

  describe ".audience_ok? — client id unconfigured" do
    it "fails closed in production" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      stub_env("GOOGLE_CLIENT_ID" => nil)
      expect(described_class.audience_ok?(google, "tok")).to be(false)
    end

    it "is permissive in dev/test so the flow stays testable" do
      stub_env("GOOGLE_CLIENT_ID" => nil)
      expect(described_class.audience_ok?(google, "tok")).to be(true)
    end
  end

  describe ".verify" do
    before { stub_env("GOOGLE_CLIENT_ID" => "our-client") }

    it "returns nil and never reads identity when the audience is wrong" do
      allow(described_class).to receive(:google_tokeninfo).and_return({ "aud" => "attacker" })
      expect(described_class).not_to receive(:extract)
      expect(described_class.verify(google, "tok")).to be_nil
    end

    it "returns the provider identity when the audience matches" do
      allow(described_class).to receive(:google_tokeninfo).and_return({ "aud" => "our-client" })
      ok = Net::HTTPOK.new("1.1", "200", "OK")
      allow(ok).to receive(:body).and_return(
        JSON.generate("sub" => "g-123", "email" => "x@y.com", "email_verified" => true, "name" => "X")
      )
      allow_any_instance_of(Net::HTTP).to receive(:request).and_return(ok)

      identity = described_class.verify(google, "tok")
      expect(identity.uid).to eq("g-123")
      expect(identity.email).to eq("x@y.com")
    end
  end

  describe ".decode_jwt_claims" do
    it "decodes a well-formed payload" do
      expect(described_class.decode_jwt_claims(jwt("appid" => "abc"))).to eq("appid" => "abc")
    end

    it "returns nil for a malformed token" do
      expect(described_class.decode_jwt_claims("garbage")).to be_nil
    end
  end
end
