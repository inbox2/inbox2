require "net/imap"

# Imports mail from an IMAP server into an organization (spec 11.2.1, A15.4)
class ImapImportService
  # Raised when the configured host resolves to a non-public IP — refusing to
  # connect prevents the import endpoint from being used as an SSRF/port-scan
  # oracle against internal services (loopback, RFC1918, cloud metadata, …).
  class BlockedHost < StandardError; end

  MAX_MESSAGES = 1000

  def initialize(organization, config)
    @organization = organization
    @host = config[:host]
    @port = config[:port] || 993
    @username = config[:username]
    @password = config[:password]
    @folder = config[:folder] || "INBOX"
    @ssl = config.fetch(:ssl, true)
  end

  def import
    imap = connect
    imap.select(@folder)

    message_ids = imap.search(["ALL"]).last(MAX_MESSAGES)
    imported = 0

    message_ids.each do |msg_id|
      envelope = imap.fetch(msg_id, "ENVELOPE").first.attr["ENVELOPE"]
      body_data = imap.fetch(msg_id, "BODY[TEXT]").first.attr["BODY[TEXT]"]

      next if message_exists?(envelope.message_id)

      begin
        create_conversation_from_envelope(envelope, body_data)
      rescue ActiveRecord::RecordNotUnique
        # Same Message-ID already imported (race with the exists? check above);
        # the partial unique index rejected it. Treat as already-imported.
        Rails.logger.info("[ImapImport] Duplicate #{envelope.message_id} — skipping")
        next
      end
      imported += 1
    end

    imap.logout
    imap.disconnect

    { imported: imported, total_available: message_ids.length }
  rescue Net::IMAP::Error, Errno::ECONNREFUSED, SocketError, BlockedHost => e
    { error: e.message, imported: 0 }
  end

  def test_connection
    imap = connect
    imap.select(@folder)
    count = imap.status(@folder, ["MESSAGES"])["MESSAGES"]
    imap.logout
    imap.disconnect
    { status: "ok", message_count: count }
  rescue Net::IMAP::Error, Errno::ECONNREFUSED, SocketError, BlockedHost => e
    { status: "error", message: e.message }
  end

  private

  def connect
    # Resolve + validate ONCE and pin to that IP to close the DNS-rebinding TOCTOU
    # (a host that resolves public for the guard, then private at connect time).
    ip = PrivateAddressGuard.pinned_public_ip(@host)
    raise BlockedHost, "Refusing to connect to non-public IMAP host" if ip.nil?

    # Plaintext: connect straight to the pinned IP (no cert to bind a hostname to),
    # which fully closes the rebind window. TLS: connect by hostname so SNI +
    # certificate verification work — a rebound internal IP won't present a cert
    # matching the hostname, so the handshake fails closed before any credentials
    # are sent (net-imap verifies by default; see start_tls_session).
    connect_host = @ssl ? @host : ip
    imap = Net::IMAP.new(connect_host, port: @port, ssl: @ssl)
    imap.login(@username, @password)
    imap
  end

  def message_exists?(message_id)
    return false if message_id.blank?

    @organization.messages.exists?(message_id_header: message_id)
  end

  def create_conversation_from_envelope(envelope, body_text)
    from = format_address(envelope.from&.first)
    to = format_address(envelope.to&.first)
    subject = envelope.subject || "(no subject)"

    conv = @organization.conversations.create!(
      subject: subject,
      from_address: from,
      to_address: to,
      status: Conversation::STATUS_OPEN
    )

    conv.messages.create!(
      organization: @organization,
      from_address: from,
      to_address: to,
      subject: subject,
      body_plain: body_text.to_s.force_encoding("UTF-8"),
      message_id_header: envelope.message_id
    )

    conv
  end

  def format_address(addr)
    return "" unless addr

    if addr.name.present?
      "#{addr.name} <#{addr.mailbox}@#{addr.host}>"
    else
      "#{addr.mailbox}@#{addr.host}"
    end
  end
end
