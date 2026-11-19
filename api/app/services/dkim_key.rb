# Central DKIM signing key for outbound mail.
#
# inbox2 uses a single platform keypair (CNAME-delegated DKIM): every connected
# domain publishes `<selector>._domainkey.<domain>  CNAME  <selector>._domainkey.<mail-domain>`
# (see DnsRecordsSerializer), so the public key lives once at the inbox2 service
# domain and one private key signs for every org with `d=<org domain>`. That
# keeps DMARC alignment (the From-header domain == the DKIM d= domain) without
# provisioning a keypair per organization.
#
# The private key is supplied out-of-band via the DKIM_PRIVATE_KEY env var (PEM,
# literal "\n" escapes allowed — same convention as APNS_KEY_P8). Generate one
# with `bin/rails dkim:generate`, publish the printed TXT record, and set the
# matching CNAME target on the service domain.
class DkimKey
  SELECTOR = ENV.fetch("DKIM_SELECTOR", "inbox2").freeze

  # PEM of the central RSA private key, or nil when unconfigured (dev without a
  # key still composes mail — it just goes out unsigned).
  def self.private_key_pem
    ENV["DKIM_PRIVATE_KEY"].presence&.gsub('\n', "\n")
  end

  def self.selector
    SELECTOR
  end

  def self.configured?
    private_key_pem.present?
  end

  # Loaded OpenSSL key, memoized per PEM. Returns nil when unconfigured or the
  # PEM is unparseable (logged once by the caller).
  def self.rsa
    pem = private_key_pem
    return nil if pem.blank?

    @rsa_cache ||= {}
    @rsa_cache[pem] ||= OpenSSL::PKey::RSA.new(pem)
  rescue OpenSSL::PKey::RSAError => e
    Rails.logger.error("[DkimKey] invalid DKIM_PRIVATE_KEY: #{e.message}")
    nil
  end
end
