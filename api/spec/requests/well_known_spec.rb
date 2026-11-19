require "rails_helper"

# Web Bot Auth key directory (Cloudflare Verified Bots). E1 mapping: spec 4.1.2 —
# the image proxy's outbound identity.
RSpec.describe "WellKnown", type: :request do
  let(:path) { "/.well-known/http-message-signatures-directory" }

  context "positive (key configured)" do
    let(:key) { OpenSSL::PKey.generate_key("ED25519") }
    before { allow(WebBotAuth).to receive(:private_key).and_return(key) }

    it "serves the signed JWKS with the draft content type, without auth" do
      get path

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/http-message-signatures-directory+json")

      # parsed_body doesn't recognize the draft content type — parse explicitly.
      jwk = JSON.parse(response.body).fetch("keys").sole
      expect(jwk.values_at("kty", "crv")).to eq(%w[OKP Ed25519])
      expect(Base64.urlsafe_decode64(jwk["x"])).to eq(key.raw_public_key)
    end

    it "signs the response over its own authority (proof of key possession)" do
      get path

      params = response.headers["Signature-Input"].delete_prefix("sig1=")
      expect(params).to include('("@authority")').and include('tag="http-message-signatures-directory"')

      signature = Base64.strict_decode64(response.headers["Signature"][/\Asig1=:(.+):\z/, 1])
      base = [%("@authority": www.example.com), %("@signature-params": #{params})].join("\n")
      expect(key.verify(nil, signature, base)).to be true
    end
  end

  context "negative" do
    it "404s when no signing key is configured" do
      allow(WebBotAuth).to receive(:private_key).and_return(nil)
      get path
      expect(response).to have_http_status(:not_found)
    end
  end
end
