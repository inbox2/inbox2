# Generate the central DKIM keypair and print the DNS record to publish.
#
#   bin/rails dkim:generate
#
# Set the printed private key as DKIM_PRIVATE_KEY on the API + SMTP sender, and
# publish the TXT record at `<selector>._domainkey.<mail-domain>` (the target the
# per-org CNAMEs point at — see DnsRecordsSerializer).
namespace :dkim do
  desc "Generate a central DKIM keypair + the DNS TXT record to publish"
  task generate: :environment do
    bits = (ENV["BITS"] || "2048").to_i
    selector = DkimKey.selector
    mail_domain = DnsRecordsSerializer::MAIL_DOMAIN

    key = OpenSSL::PKey::RSA.new(bits)
    public_der = key.public_key.to_der
    public_b64 = Base64.strict_encode64(public_der)

    puts "# --- DKIM_PRIVATE_KEY (set on api + mta/cmd/smtp) ---"
    puts key.to_pem
    puts "# --- DNS record: publish at the CNAME target ---"
    puts %(#{selector}._domainkey.#{mail_domain}. IN TXT "v=DKIM1; k=rsa; p=#{public_b64}")
    puts
    puts "# Each connected domain delegates to this key via the CNAME that"
    puts "# DnsRecordsSerializer already emits — no per-org record needed."
  end
end
