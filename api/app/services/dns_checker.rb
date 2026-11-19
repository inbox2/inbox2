# Resolves a domain's live DNS and checks it against the records inbox2 requires
# (see DnsRecordsSerializer). MX is the record that matters for inbound routing;
# `mx_ok` drives auto-verification, the per-record map drives the setup UI.
class DnsChecker
  MAIL_DOMAIN = DnsRecordsSerializer::MAIL_DOMAIN

  def initialize(domain_record, resolver: DnsResolver.new)
    @domain_record = domain_record
    @resolver = resolver
  end

  # => { mx_ok:, all_ok:, checks: { mx:, spf:, dmarc:, dkim: } }
  def call
    domain = @domain_record.name
    selector = DkimKey.selector

    mx_ok = @resolver.mx(domain).any? { |h| host_eq?(h, "mx.#{MAIL_DOMAIN}") }
    spf_ok = @resolver.txt(domain).any? { |t| t.include?("include:_spf.#{MAIL_DOMAIN}") }
    dmarc_ok = @resolver.txt("_dmarc.#{domain}").any? { |t| t.strip.start_with?("v=DMARC1") }
    dkim_ok = host_eq?(@resolver.cname("#{selector}._domainkey.#{domain}"), "#{selector}._domainkey.#{MAIL_DOMAIN}")

    {
      mx_ok: mx_ok,
      all_ok: mx_ok && spf_ok && dmarc_ok && dkim_ok,
      checks: { mx: mx_ok, spf: spf_ok, dmarc: dmarc_ok, dkim: dkim_ok }
    }
  end

  private

  # Compare hostnames case-insensitively, ignoring a trailing dot.
  def host_eq?(a, b)
    return false if a.nil?
    a.to_s.chomp(".").casecmp?(b.chomp("."))
  end
end
