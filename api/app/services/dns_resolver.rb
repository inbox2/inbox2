require "resolv"
require "timeout"

# Thin wrapper around Ruby's stdlib resolver so DnsChecker can be unit-tested
# with a fake (no network). Each lookup is time-bounded and fails soft to an
# empty result rather than raising.
class DnsResolver
  TIMEOUT = 5

  # MX exchange hostnames (trailing dot stripped).
  def mx(domain)
    lookup { |d| d.getresources(domain, Resolv::DNS::Resource::IN::MX).map { |r| r.exchange.to_s } } || []
  end

  # TXT record strings (each record's chunks joined).
  def txt(host)
    lookup { |d| d.getresources(host, Resolv::DNS::Resource::IN::TXT).map { |r| r.strings.join } } || []
  end

  # The CNAME target hostname, or nil.
  def cname(host)
    (lookup { |d| d.getresources(host, Resolv::DNS::Resource::IN::CNAME).map { |r| r.name.to_s } } || []).first
  end

  # A-record IPv4 addresses (strings). Used to spot a Cloudflare-proxied
  # (orange-cloud) record, whose A points at Cloudflare's edge instead of
  # following the CNAME.
  def a(host)
    lookup { |d| d.getresources(host, Resolv::DNS::Resource::IN::A).map { |r| r.address.to_s } } || []
  end

  # Authoritative nameserver hostnames (lowercased, trailing dot stripped) — used
  # to detect the DNS provider (e.g. *.ns.cloudflare.com) so setup can offer a
  # one-click auto-configure path.
  def ns(domain)
    (lookup { |d| d.getresources(domain, Resolv::DNS::Resource::IN::NS).map { |r| r.name.to_s } } || [])
      .map { |h| h.downcase.chomp(".") }
  end

  private

  def lookup
    Timeout.timeout(TIMEOUT) { Resolv::DNS.open { |dns| yield dns } }
  rescue StandardError => e
    Rails.logger.debug("DnsResolver: #{e.class}: #{e.message}")
    nil
  end
end
