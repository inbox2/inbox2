require "ipaddr"
require "resolv"

# SSRF guard for the image proxy: only permit fetching URLs that resolve to
# public, routable IPs. Blocks loopback, private (RFC1918), CGNAT, link-local
# (incl. the 169.254.169.254 cloud-metadata address), unique-local, multicast
# and reserved ranges — so the proxy can't be turned into a window onto internal
# services. Every redirect hop is re-validated by the caller.
class PrivateAddressGuard
  BLOCKED_V4 = [
    IPAddr.new("0.0.0.0/8"),       # "this" network
    IPAddr.new("10.0.0.0/8"),      # RFC1918
    IPAddr.new("100.64.0.0/10"),   # CGNAT
    IPAddr.new("127.0.0.0/8"),     # loopback
    IPAddr.new("169.254.0.0/16"),  # link-local + cloud metadata
    IPAddr.new("172.16.0.0/12"),   # RFC1918
    IPAddr.new("192.0.0.0/24"),    # IETF protocol assignments
    IPAddr.new("192.168.0.0/16"),  # RFC1918
    IPAddr.new("198.18.0.0/15"),   # benchmarking
    IPAddr.new("224.0.0.0/4"),     # multicast
    IPAddr.new("240.0.0.0/4")     # reserved
  ].freeze

  BLOCKED_V6 = [
    IPAddr.new("::1/128"),  # loopback
    IPAddr.new("::/128"),   # unspecified
    IPAddr.new("::ffff:0:0/96"), # IPv4-mapped (also unwrapped below and checked as v4)
    IPAddr.new("64:ff9b::/96"), # NAT64 well-known prefix (embeds an IPv4 target)
    IPAddr.new("64:ff9b:1::/48"), # NAT64 local-use
    IPAddr.new("100::/64"), # discard-only
    IPAddr.new("2001:db8::/32"), # documentation
    IPAddr.new("2002::/16"), # 6to4 (embeds an IPv4 target)
    IPAddr.new("fc00::/7"), # unique local
    IPAddr.new("fe80::/10"), # link-local
    IPAddr.new("ff00::/8") # multicast
  ].freeze

  # True only when url is http(s), has a host, and *every* address that host
  # resolves to is public. (All-or-nothing: a host with one private answer is
  # rejected to defeat DNS-rebinding tricks.)
  def self.public_url?(raw_url)
    uri = URI.parse(raw_url.to_s)
    return false unless uri.is_a?(URI::HTTP) && uri.host.present?

    public_host?(uri.host)
  rescue URI::InvalidURIError, IPAddr::Error
    false
  end

  # True only when host resolves and *every* address it resolves to is public.
  # For non-HTTP outbound connections (e.g. IMAP) where there's no URL to vet.
  def self.public_host?(host)
    return false if host.to_s.strip.empty?

    addresses = resolve(host)
    return false if addresses.empty?

    addresses.all? { |ip| public_ip?(ip) }
  rescue IPAddr::Error
    false
  end

  def self.public_ip?(ip_string)
    ip = IPAddr.new(ip_string.to_s)
    # ::ffff:127.0.0.1 is loopback wearing an IPv6 coat: judge the IPv4 inside.
    ip = ip.native if ip.ipv6? && ip.ipv4_mapped?
    blocked = ip.ipv4? ? BLOCKED_V4 : BLOCKED_V6
    blocked.none? { |range| range.include?(ip) }
  rescue IPAddr::Error
    false
  end

  # Resolve `host` ONCE, require every answer to be public, and return a single
  # validated IP literal to pin the connection to. Connecting to this pinned IP
  # (Net::HTTP#ipaddr= for HTTP, or as the connect host for plaintext sockets)
  # closes the DNS-rebinding TOCTOU where a second lookup at connect time could
  # return a private address after the guard validated a public one. Returns nil
  # when the host doesn't resolve or any answer is non-public.
  def self.pinned_public_ip(host)
    return nil if host.to_s.strip.empty?

    addresses = resolve(host)
    return nil if addresses.empty?
    return nil unless addresses.all? { |ip| public_ip?(ip) }

    # IPv4 first: a dual-stack site (every Cloudflare one) answers AAAA too, and a
    # pod or dev machine without an IPv6 route can't reach it (EHOSTUNREACH).
    addresses.find { |ip| IPAddr.new(ip).ipv4? } || addresses.first
  rescue IPAddr::Error
    nil
  end

  # Same as #pinned_public_ip but takes a URL: validates scheme/host then pins.
  # Returns [uri, pinned_ip] or nil. Use the pinned_ip as Net::HTTP#ipaddr so SNI
  # and the Host header stay the original hostname while the socket connects to
  # the pre-validated address.
  def self.pinned_url(raw_url)
    uri = URI.parse(raw_url.to_s)
    return nil unless uri.is_a?(URI::HTTP) && uri.host.present?

    ip = pinned_public_ip(uri.host)
    ip && [uri, ip]
  rescue URI::InvalidURIError, IPAddr::Error
    nil
  end

  # Resolve a host to its IP literals. An IP literal host resolves to itself.
  def self.resolve(host)
    return [host] if ip_literal?(host)

    Resolv.getaddresses(host)
  rescue Resolv::ResolvError
    []
  end

  def self.ip_literal?(host)
    IPAddr.new(host.to_s)
    true
  rescue IPAddr::Error
    false
  end
end
