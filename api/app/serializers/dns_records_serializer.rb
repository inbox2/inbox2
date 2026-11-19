class DnsRecordsSerializer
  include Alba::Resource

  # The inbox2 mail service domain customers point their DNS at. Overridable per
  # deployment; defaults to the production service domain.
  MAIL_DOMAIN = ENV.fetch("INBOX2_MAIL_DOMAIN", "inbox2.com").freeze

  # The required records for a domain (spec 2.3.2, 2.3.3). Shared source of truth
  # for the setup UI, the DnsChecker verification, AND the Cloudflare auto-config
  # writer — so the three can never drift. Each record carries the pending-DNS
  # status; the top-level `status` reflects the domain's actual verification state.
  def self.required_records(domain, status: Domain::STATUS_PENDING_DNS)
    selector = DkimKey.selector
    [
      # Single MX (Gmail-style); scaled out behind one hostname for redundancy.
      { type: "MX", host: domain, value: "mx.#{MAIL_DOMAIN}", priority: 10, status: status },
      { type: "TXT", host: domain, value: "v=spf1 include:_spf.#{MAIL_DOMAIN} ~all", status: status },
      { type: "TXT", host: "_dmarc.#{domain}", value: "v=DMARC1; p=quarantine; rua=mailto:dmarc@#{MAIL_DOMAIN}", status: status },
      { type: "CNAME", host: "#{selector}._domainkey.#{domain}", value: "#{selector}._domainkey.#{MAIL_DOMAIN}", status: status }
    ]
  end

  attribute :domain do |dom|
    dom.name
  end

  attribute :records do |dom|
    DnsRecordsSerializer.required_records(dom.name)
  end

  attribute :status do |dom|
    dom.status
  end
end
