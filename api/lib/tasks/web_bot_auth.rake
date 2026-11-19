# Web Bot Auth key management (Cloudflare Verified Bots).
namespace :web_bot_auth do
  desc "Generate an Ed25519 keypair for Web Bot Auth and print setup instructions"
  task generate_key: :environment do
    key = OpenSSL::PKey.generate_key("ED25519")
    x = Base64.urlsafe_encode64(key.raw_public_key, padding: false)
    thumbprint = Base64.urlsafe_encode64(
      OpenSSL::Digest::SHA256.digest(%({"crv":"Ed25519","kty":"OKP","x":"#{x}"})), padding: false
    )

    puts key.private_to_pem
    puts "Public JWK:   #{({ kty: 'OKP', crv: 'Ed25519', x: x, use: 'sig' }).to_json}"
    puts "JWK keyid:    #{thumbprint}"
    puts
    puts "Setup (secrets stay local-only — never commit the PEM):"
    puts "  1. Store the PEM above as the WEB_BOT_AUTH_KEY env var (k8s secret in prod):"
    puts "       kubectl -n <ns> create secret generic web-bot-auth --from-literal=WEB_BOT_AUTH_KEY='<pem>'"
    puts "  2. Optionally set WEB_BOT_AUTH_AGENT (default #{WebBotAuth::DEFAULT_AGENT})."
    puts "     Its origin must serve #{WebBotAuth::DIRECTORY_PATH}."
    puts "  3. Verify: curl https://<api-host>#{WebBotAuth::DIRECTORY_PATH}"
    puts "  4. Apply at https://developers.cloudflare.com/bots/concepts/bot/verified-bots/"
  end
end
