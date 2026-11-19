require "net/smtp"

module DeliveryProviders
  # Generic SMTP relay (DeliveryChannel KIND_SMTP_RELAY → "Custom SMTP"). Relays
  # the composed raw MIME through any provider's SMTP endpoint with the org's own
  # credentials. `security` picks the transport: starttls (default), tls (implicit
  # SMTPS), or none.
  class Smtp < Base
    def deliver(context)
      host = cfg(:host)
      port = (cfg(:port) || 587).to_i
      security = (cfg(:security) || "starttls").to_s

      smtp = connect_to(host, port) or return Result.permanent_failure("SMTP host #{host} is not a public address")
      smtp.open_timeout = 15
      smtp.read_timeout = 30
      case security
      when "tls"
        smtp.enable_tls
      when "none"
        # plain — no transport encryption
      else
        smtp.enable_starttls_auto
      end

      auth = cfg(:username) ? [:login, cfg(:username), cfg(:password)] : []
      smtp.start("localhost", *auth) do |s|
        s.send_message(context.raw_mime, context.from, *Array(context.to), *Array(context.cc), *Array(context.bcc))
      end

      Result.ok
    rescue Net::SMTPAuthenticationError, Net::SMTPFatalError => e
      # 5xx — bad credentials or a hard reject; retrying won't help.
      Result.permanent_failure(e.message)
    rescue Net::SMTPServerBusy, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, SocketError => e
      Result.transient(e.message)
    rescue => e
      Result.transient(e.message)
    end

    # Connect + authenticate, then disconnect without sending.
    def verify
      host = cfg(:host)
      port = (cfg(:port) || 587).to_i
      security = (cfg(:security) || "starttls").to_s

      smtp = connect_to(host, port) or return Result.permanent_failure("SMTP host #{host} is not a public address")
      smtp.open_timeout = 15
      smtp.read_timeout = 20
      smtp.enable_tls if security == "tls"
      smtp.enable_starttls_auto if security == "starttls"

      auth = cfg(:username) ? [:login, cfg(:username), cfg(:password)] : []
      smtp.start("localhost", *auth) { |s| s.helo("localhost") }
      Result.ok
    rescue Net::SMTPAuthenticationError, Net::SMTPFatalError => e
      Result.permanent_failure(e.message)
    rescue => e
      Result.transient(e.message)
    end

    private

    # An admin-supplied host must not become a port scanner for the cluster:
    # resolve once through the shared SSRF guard (PrivateAddressGuard) and
    # connect to that address, keeping the hostname for SNI/certificate checks.
    # Dev/test keep talking to local sinks. Returns nil for a blocked host.
    def connect_to(host, port)
      address = host
      unless Rails.env.development? || Rails.env.test?
        address = PrivateAddressGuard.pinned_public_ip(host)
        return nil unless address
      end

      smtp = Net::SMTP.new(address, port)
      smtp.tls_hostname = host if smtp.respond_to?(:tls_hostname=)
      smtp
    end
  end
end
