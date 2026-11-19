# E2EE message sealing — the single source of truth for "does this domain seal?"
# (docs/E2EE.md Phase A). Three independent gates, all required:
#
#   entitlement  — the org's plan includes E2EE   (Organization#e2ee_entitled?)
#   switch       — the domain opted in            (domains.e2ee_enabled)
#   availability — not force-disabled by ops      (INBOX2_E2EE_FORCE_OFF)
#
# Force-off defaults ON outside production so dev/test never seal accidentally;
# set INBOX2_E2EE_FORCE_OFF=false locally to exercise the sealed path, or =true
# in production as the emergency kill switch.
module E2ee
  module_function

  # Ops kill switch. Unset ⇒ forced off everywhere except production.
  def force_off?
    default = Rails.env.production? ? "false" : "true"
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("INBOX2_E2EE_FORCE_OFF", default))
  end

  def available?
    !force_off?
  end

  # The one resolver the MX domain-lookup (and everything else) asks. A domain
  # seals only when entitled AND switched on AND not force-disabled.
  def effective?(domain)
    return false unless domain && available?

    domain.e2ee_enabled? && domain.organization.e2ee_entitled?
  end

  # Server-side secret for the threading HMACs (msgid/refs/subject). Shared with
  # the MX via MX_THREADING_HMAC_KEY so both sides derive identical values —
  # required for mixed-mode threading (sealed replies to plaintext mail).
  def threading_hmac_key
    ENV["INBOX2_THREADING_HMAC_KEY"]
  end

  # Deterministic keyed threading hash — MUST match seal.ThreadingHMAC in the Go
  # MX (hex HMAC-SHA256). Keyed so stored columns can't confirm a guessed
  # Message-ID or subject. Nil when the shared key isn't configured (plaintext
  # threading still works without HMACs; sealed threading requires them).
  def threading_hmac(value)
    key = threading_hmac_key
    return nil if key.blank? || value.blank?

    OpenSSL::HMAC.hexdigest("SHA256", key, value)
  end

  # Rails-side twin of the MX rule: only subjects whose NORMALIZED form is at
  # least this long participate in subject-fallback threading.
  MIN_SUBJECT_THREADING_LENGTH = 5

  def subject_threading_hmac(subject)
    normalized = SubjectNormalizer.normalize(subject)
    return nil if normalized.length < MIN_SUBJECT_THREADING_LENGTH

    threading_hmac(normalized)
  end

  # ── Outbound sealing crypto (docs/E2EE.md Phase I) ─────────────────────────
  # rbnacl/libsodium, interop-locked to the Go MX (mta/internal/seal) and the
  # web client (lib/e2ee.js): XChaCha20-Poly1305 AEAD + crypto_box_seal.
  # Lazily loaded so environments without libsodium still boot (sealing paths
  # then raise with a clear message).

  # The MTA delivery public key: the Go SMTP sender holds the private half and
  # decrypts queued outbound MIME in RAM at delivery time. Generate a pair with
  # `cd mta && go run ./cmd/deliverykey`.
  def mta_delivery_public_key
    ENV["INBOX2_MTA_DELIVERY_PUBLIC_KEY"]
  end

  def sodium!
    require "rbnacl"
    RbNaCl
  rescue LoadError => e
    raise "E2EE outbound sealing requires libsodium (rbnacl): #{e.message}"
  end

  def generate_dek
    sodium!::Random.random_bytes(32)
  end

  # Returns [nonce, ciphertext] (raw bytes) — matches seal.Encrypt in Go.
  def aead_encrypt(dek, plaintext, aad)
    aead = sodium!::AEAD::XChaCha20Poly1305IETF.new(dek)
    nonce = sodium!::Random.random_bytes(aead.nonce_bytes)
    [nonce, aead.encrypt(nonce, plaintext, aad)]
  end

  # crypto_box_seal to a base64 X25519 public key — matches seal.SealDEK in Go.
  def seal_to_public_key(public_key_b64, bytes)
    public_key = sodium!::PublicKey.new(Base64.strict_decode64(public_key_b64))
    sodium!::Boxes::Sealed.from_public_key(public_key).box(bytes)
  end
end
