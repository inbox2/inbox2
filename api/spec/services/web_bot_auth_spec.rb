require "rails_helper"

# Web Bot Auth — RFC 9421 message signatures for the image proxy (Cloudflare
# Verified Bots). E1 mapping: spec 4.1.2 (image proxying, deliverability of the
# privacy fetch).
RSpec.describe WebBotAuth do
  let(:key) { OpenSSL::PKey.generate_key("ED25519") }

  before { allow(described_class).to receive(:private_key).and_return(key) }

  # Rebuild the RFC 9421 signature base from emitted headers and verify the
  # Ed25519 signature against the public key.
  def verify(headers, covered)
    params = headers["Signature-Input"].delete_prefix("sig1=")
    signature = Base64.strict_decode64(headers["Signature"][/\Asig1=:(.+):\z/, 1])
    base = (covered.map { |name, value| %("#{name}": #{value}) } +
            [%("@signature-params": #{params})]).join("\n")
    key.verify(nil, signature, base)
  end

  describe ".enabled?" do
    it "is on with a key and off without one" do
      expect(described_class.enabled?).to be true
      allow(described_class).to receive(:private_key).and_return(nil)
      expect(described_class.enabled?).to be false
    end
  end

  describe ".private_key" do
    it "reads an Ed25519 PEM from ENV, tolerating literal \\n newlines" do
      allow(described_class).to receive(:private_key).and_call_original
      pem = OpenSSL::PKey.generate_key("ED25519").private_to_pem
      ENV["WEB_BOT_AUTH_KEY"] = pem.gsub("\n", '\n')
      described_class.reset!
      expect(described_class.private_key).to be_a(OpenSSL::PKey::PKey)
    ensure
      ENV.delete("WEB_BOT_AUTH_KEY")
      described_class.reset!
    end

    it "is nil (disabled) for an unreadable key" do
      allow(described_class).to receive(:private_key).and_call_original
      ENV["WEB_BOT_AUTH_KEY"] = "not a pem"
      described_class.reset!
      expect(described_class.private_key).to be_nil
      expect(described_class.enabled?).to be false
    ensure
      ENV.delete("WEB_BOT_AUTH_KEY")
      described_class.reset!
    end
  end

  describe ".public_jwk / .key_id" do
    it "exposes the OKP/Ed25519 JWK with the raw public key" do
      jwk = described_class.public_jwk
      expect(jwk[:kty]).to eq("OKP")
      expect(jwk[:crv]).to eq("Ed25519")
      expect(Base64.urlsafe_decode64(jwk[:x])).to eq(key.raw_public_key)
    end

    it "derives the keyid as the RFC 7638 thumbprint of the JWK" do
      x = Base64.urlsafe_encode64(key.raw_public_key, padding: false)
      expected = Base64.urlsafe_encode64(
        OpenSSL::Digest::SHA256.digest(%({"crv":"Ed25519","kty":"OKP","x":"#{x}"})), padding: false
      )
      expect(described_class.key_id).to eq(expected)
    end
  end

  describe ".sign!" do
    let(:request) { Net::HTTP::Get.new(URI("https://cdn.example.com/pixel.png")) }

    it "adds a verifiable web-bot-auth signature over @authority and signature-agent" do
      described_class.sign!(request, authority: "cdn.example.com")

      expect(request["Signature-Agent"]).to eq(%("#{described_class.agent}"))
      expect(request["Signature-Input"]).to include('("@authority" "signature-agent")')
        .and include('alg="ed25519"').and include('tag="web-bot-auth"')
        .and include(%(keyid="#{described_class.key_id}")).and match(/created=\d+;expires=\d+/)

      headers = { "Signature-Input" => request["Signature-Input"], "Signature" => request["Signature"] }
      covered = { "@authority" => "cdn.example.com", "signature-agent" => request["Signature-Agent"] }
      expect(verify(headers, covered)).to be true
    end

    it "leaves the request untouched when disabled (negative)" do
      allow(described_class).to receive(:private_key).and_return(nil)
      described_class.sign!(request, authority: "cdn.example.com")
      expect(request["Signature"]).to be_nil
      expect(request["Signature-Input"]).to be_nil
      expect(request["Signature-Agent"]).to be_nil
    end

    it "does not verify against a different authority (negative)" do
      described_class.sign!(request, authority: "cdn.example.com")
      headers = { "Signature-Input" => request["Signature-Input"], "Signature" => request["Signature"] }
      covered = { "@authority" => "evil.example.com", "signature-agent" => request["Signature-Agent"] }
      expect(verify(headers, covered)).to be false
    end
  end

  describe ".directory_headers" do
    it "signs the directory's own authority with the directory tag" do
      headers = described_class.directory_headers(authority: "api.inbox2.com")
      expect(headers["Signature-Input"]).to include('("@authority")')
        .and include('tag="http-message-signatures-directory"')
      expect(verify(headers, { "@authority" => "api.inbox2.com" })).to be true
    end
  end

  describe ".authority_for" do
    it "lowercases the host and omits default ports, keeping explicit ones" do
      expect(described_class.authority_for(URI("https://CDN.Example.com/x"))).to eq("cdn.example.com")
      expect(described_class.authority_for(URI("http://cdn.example.com/x"))).to eq("cdn.example.com")
      expect(described_class.authority_for(URI("https://cdn.example.com:8443/x"))).to eq("cdn.example.com:8443")
    end
  end
end
