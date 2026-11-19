# Web Bot Auth — RFC 9421 HTTP Message Signatures for the image proxy's outbound
# fetches, per Cloudflare's Verified Bots program (and the IETF web-bot-auth
# drafts). Lets bot-managed CDNs cryptographically verify our fetches instead of
# 403ing them by TLS fingerprint; applying with well-formed signatures also waives
# the program's 1,000-requests/day minimum.
#
# Three pieces:
#   - sign!(request, authority:)  — adds Signature-Input / Signature /
#     Signature-Agent to an outbound Net::HTTP request (tag "web-bot-auth").
#   - directory_headers(authority:) — the same signature over our own authority for
#     the key-directory response (tag "http-message-signatures-directory"), proving
#     key possession to the directory's fetcher.
#   - public_jwk / key_id — the Ed25519 public key as an OKP JWK and its RFC 7638
#     thumbprint, served from /.well-known/http-message-signatures-directory.
#
# The private key is an Ed25519 PEM in ENV["WEB_BOT_AUTH_KEY"] (k8s secret /
# local-only, per the deployment secrets policy — generate with
# `rake web_bot_auth:generate_key`). Unset → signing is OFF and the proxy fetches
# exactly as before; nothing here is on the request path until the key exists.
module WebBotAuth
  # The URL whose origin serves our key directory; sent (quoted, an sf-string) as
  # the Signature-Agent header and covered by the signature.
  DEFAULT_AGENT = "https://api.inbox2.com".freeze
  SIGNATURE_TTL = 5.minutes
  REQUEST_TAG = "web-bot-auth".freeze
  DIRECTORY_TAG = "http-message-signatures-directory".freeze
  DIRECTORY_CONTENT_TYPE = "application/http-message-signatures-directory+json".freeze
  DIRECTORY_PATH = "/.well-known/http-message-signatures-directory".freeze

  class << self
    def enabled? = private_key.present?

    def agent = ENV.fetch("WEB_BOT_AUTH_AGENT", DEFAULT_AGENT)

    # Ed25519 private key from the environment; memoized. Tolerates the common
    # k8s-secret mangling of newlines into literal "\n".
    def private_key
      return @private_key if defined?(@private_key)

      pem = ENV["WEB_BOT_AUTH_KEY"].presence
      @private_key = pem && begin
        OpenSSL::PKey.read(pem.gsub('\n', "\n"))
      rescue OpenSSL::PKey::PKeyError => e
        Rails.logger.error("[WebBotAuth] unreadable WEB_BOT_AUTH_KEY: #{e.message}")
        nil
      end
    end

    # For specs: forget the memoized key so a changed ENV takes effect.
    def reset!
      remove_instance_variable(:@private_key) if defined?(@private_key)
    end

    # The public key as an OKP/Ed25519 JWK (the directory's `keys` entry).
    def public_jwk
      { kty: "OKP", crv: "Ed25519", x: b64url(private_key.raw_public_key), use: "sig" }
    end

    # RFC 7638 JWK thumbprint (the signature `keyid`): SHA-256 over the required
    # members in lexicographic order, base64url without padding.
    def key_id
      canonical = %({"crv":"Ed25519","kty":"OKP","x":"#{b64url(private_key.raw_public_key)}"})
      b64url(OpenSSL::Digest::SHA256.digest(canonical))
    end

    # Sign an outbound Net::HTTP request (tag "web-bot-auth"). Covered components:
    # @authority (the upstream host) and signature-agent. No-op when disabled.
    def sign!(request, authority:)
      return request unless enabled?

      request["Signature-Agent"] = sf_string(agent)
      components = { "@authority" => authority, "signature-agent" => sf_string(agent) }
      params = signature_params(components.keys, tag: REQUEST_TAG)
      request["Signature-Input"] = "sig1=#{params}"
      request["Signature"] = "sig1=:#{sign_base(components, params)}:"
      request
    end

    # Signature headers for the key-directory response itself (tag
    # "http-message-signatures-directory"), binding our own authority.
    def directory_headers(authority:)
      components = { "@authority" => authority }
      params = signature_params(components.keys, tag: DIRECTORY_TAG)
      {
        "Signature-Input" => "sig1=#{params}",
        "Signature" => "sig1=:#{sign_base(components, params)}:"
      }
    end

    # RFC 9421 @authority for a URI: lowercase host, default port omitted.
    def authority_for(uri)
      default = (uri.scheme == "https" ? 443 : 80)
      host = uri.host.to_s.downcase
      uri.port == default ? host : "#{host}:#{uri.port}"
    end

    private

    # `("@authority" "signature-agent");created=…;expires=…;keyid="…";alg="ed25519";nonce="…";tag="…"`
    def signature_params(component_names, tag:)
      now = Time.current.to_i
      list = component_names.map { |c| %("#{c}") }.join(" ")
      "(#{list});created=#{now};expires=#{now + SIGNATURE_TTL.to_i};" \
        "keyid=#{sf_string(key_id)};alg=#{sf_string('ed25519')};" \
        "nonce=#{sf_string(SecureRandom.base64(32))};tag=#{sf_string(tag)}"
    end

    # The RFC 9421 signature base: one `"name": value` line per covered component,
    # then the @signature-params line. Lines joined with \n, no trailing newline.
    def sign_base(components, params)
      lines = components.map { |name, value| %("#{name}": #{value}) }
      lines << %("@signature-params": #{params})
      Base64.strict_encode64(private_key.sign(nil, lines.join("\n")))
    end

    def sf_string(value) = %("#{value}")

    def b64url(bytes) = Base64.urlsafe_encode64(bytes, padding: false)
  end
end
