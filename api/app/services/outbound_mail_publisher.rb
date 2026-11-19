# Publishes outbound messages to NATS JetStream for the Go SMTP sender to deliver.
#
# Creates a DeliveryStatus record and publishes the message to the MAIL_OUTBOUND
# stream. The Go sender consumes it, DKIM-signs it, delivers via SMTP, and
# publishes the result back to MAIL_DELIVERY_STATUS for Rails to process.
#
# Spec references: 16.2.2, 20.2.1, 39.4
class OutboundMailPublisher
  # The whole message rides one NATS message (64MB max, base64 in JSON), and
  # most receiving servers refuse mail over ~25MB anyway: Gmail's and Outlook's cap.
  MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024
  STREAM_NAME = "MAIL_OUTBOUND"
  SUBJECT_PREFIX = "mail.outbound."

  # Queues a ready-made job for the Go sender (the ESP builds its own payload:
  # Esp::Publisher). `destination` is the recipient domain.
  def self.publish_payload(destination, payload)
    publisher = allocate
    nats = publisher.send(:connect_nats)
    js = nats.jetstream
    publisher.send(:ensure_stream, js)
    js.publish("#{SUBJECT_PREFIX}#{destination}", JSON.generate(payload))
  ensure
    nats&.close
  end

  def initialize(message, attachments: nil)
    @message = message
    @organization = message.organization
    # Explicit attachment set for composing BEFORE the rows are linked (the
    # Phase-I sealing flow composes the MIME pre-save); defaults to the
    # message's linked attachments.
    @attachments = attachments
  end

  # Composes the RFC 5322 MIME for this message (public for the sealing flow,
  # which encrypts the result instead of queuing it in plaintext).
  def compose_mime
    compose_rfc5322
  end

  # Publishes the message for delivery, one DeliveryStatus per DESTINATION —
  # per recipient domain for the builtin MTA, or a single row for a BYO-ESP
  # channel (it fans out to every domain itself). Splitting matters because a
  # queued job is only safe to retry while it maps to exactly one SMTP envelope:
  # `sendEnvelope` fails before DATA, so a failed job means nobody got the mail.
  # One job spanning domains would mean a partial success plus a whole-job retry
  # mails the successful recipients twice — and the Go sender only ever does one
  # MX lookup (rcpt_to[0]'s domain) anyway, so foreign recipients were rejected
  # by the wrong MX and took the whole envelope down with them.
  #
  # On retry, pass the existing `delivery_status`: only THAT destination is
  # re-published (its own recipients, its own attempt history) — never the whole
  # list, which by then may include recipients that already received the mail.
  #
  # Returns the DeliveryStatus rows it published (one per destination).
  def publish(delivery_status: nil)
    channel = DeliveryChannel.active_for(@organization)

    # Retry: re-publish exactly the destination this row owns. A retry may run
    # after the org switched providers — keep the attempt history on its
    # original channel so the delivery log stays coherent.
    if delivery_status
      channel = delivery_status.delivery_channel || channel
      recipients = delivery_status.recipient_list.presence || build_recipient_list
      return [publish_destination(delivery_status, channel, recipients)]
    end

    # Drop recipients on the org suppression list (hard bounces, complaints,
    # exhausted retries) — sending to known-dead addresses tanks reputation.
    recipients = build_recipient_list
    allowed = recipients.reject { |addr| SuppressionEntry.suppressed?(@organization, addr) }

    if allowed.empty?
      status = destination_status(channel, destination: extract_domain(recipients.first), recipients: recipients)
      mark_suppressed!(status, recipients)
      return [status]
    end

    # Customer-owned ESP: hand the composed message to the provider adapter
    # instead of NATS/the inbox2 MTA. A sealed row cannot be re-composed for a
    # provider API (no plaintext server-side) — fail fast with a clear reason
    # rather than sending an empty message (docs/E2EE.md Phase I).
    if channel.custom?
      status = destination_status(channel, destination: "#{DeliveryStatus::DESTINATION_ESP_PREFIX}#{channel.kind}", recipients: allowed)
      if @message.sealed?
        status.update!(status: DeliveryStatus::STATUS_FAILED, failed_at: Time.current,
          dsn_diagnostic: "sealed message cannot be delivered via a custom ESP")
        Rails.logger.warn("[OutboundMailPublisher] Sealed message #{@message.key} cannot use BYO-ESP channel #{channel.kind}")
        return [status]
      end
      return [deliver_via_provider(status, channel, allowed)]
    end

    suppressed = recipients.size - allowed.size
    allowed.group_by { |addr| extract_domain(addr) }.map do |domain, domain_recipients|
      status = destination_status(channel, destination: domain, recipients: domain_recipients)
      Rails.logger.info("[OutboundMailPublisher] #{@message.key} → #{domain} (#{domain_recipients.size} rcpt, suppressed=#{suppressed})") if suppressed.positive?
      publish_destination(status, channel, domain_recipients)
    end
  end

  private

  # The DeliveryStatus for one destination, reused across re-enqueues so a
  # re-published message accrues attempts on one row per destination instead of
  # spawning duplicates.
  def destination_status(channel, destination:, recipients:)
    status = @message.delivery_statuses.find_by(destination: destination) ||
      @message.delivery_statuses.build(delivery_channel: channel, destination: destination)
    status.recipient_list = recipients
    status.status = DeliveryStatus::STATUS_QUEUED if status.new_record?
    status.save!
    status
  end

  # Queues one destination's envelope on NATS for the Go sender. `published_at`
  # is stamped only after the publish returns: a row that exists but was never
  # published is a FAILED publish, and OutboundDeliveryJob re-publishes it
  # instead of reading its mere presence as "already sent".
  def publish_destination(delivery_status, channel, recipients)
    payload = build_payload(delivery_status, channel, recipients)
    subject = "#{SUBJECT_PREFIX}#{delivery_status.destination.presence || extract_domain(recipients.first)}"

    nats = connect_nats
    js = nats.jetstream
    ensure_stream(js)
    js.publish(subject, JSON.generate(payload))

    delivery_status.update!(published_at: Time.current)
    Rails.logger.info("[OutboundMailPublisher] Published message #{@message.key} to #{subject} rcpt=#{recipients.size} attachments=#{@message.attachments.count}")
    delivery_status
  rescue => e
    Rails.logger.error("[OutboundMailPublisher] Failed to publish #{@message.key} to #{delivery_status.destination}: #{e.class}: #{e.message}")
    raise
  end

  # Sends through a customer-configured ESP (DeliveryProviders adapter). Unlike
  # the NATS path, the provider HTTP/SMTP call is synchronous and returns an
  # accept/reject right here, so we record the attempt + drive the retry timer
  # ourselves (the NATS feedback loop never fires for these).
  def deliver_via_provider(delivery_status, channel, recipients)
    delivery_status.update!(status: DeliveryStatus::STATUS_SENDING)

    result = DeliveryProviders.for(channel).deliver(build_context(recipients))
    retrier = DeliveryRetryService.new(delivery_status)

    if result.accepted?
      retrier.record_attempt(result: "success", message: result.provider_message_id)
      Rails.logger.info("[OutboundMailPublisher] Delivered #{@message.key} via #{channel.kind} id=#{result.provider_message_id}")
    elsif result.permanent?
      retrier.record_attempt(result: "permanent_failure", message: result.error)
      Rails.logger.warn("[OutboundMailPublisher] #{channel.kind} permanently rejected #{@message.key}: #{result.error}")
    else
      # Pre-mark deferred so DeliveryRetryService keeps it retryable — its
      # should_retry? reads the current status, which the NATS flow sets upstream
      # but the synchronous provider flow must set here.
      delivery_status.update!(status: DeliveryStatus::STATUS_DEFERRED)
      retrier.record_attempt(result: "transient_failure", message: result.error)
      delivery_status.reload

      if delivery_status.status == DeliveryStatus::STATUS_DEFERRED && retrier.should_retry?
        OutboundRetryJob.set(wait: retrier.next_retry_delay).perform_later(delivery_status.id)
      end
      Rails.logger.warn("[OutboundMailPublisher] #{channel.kind} deferred #{@message.key}: #{result.error}")
    end

    delivery_status
  end

  # Builds the provider Context: the composed raw MIME plus the structured fields
  # so each adapter can use whichever its API speaks.
  def build_context(recipients)
    DeliveryProviders::Context.new(
      from: MailHeaderEncoding.bare_addresses(@message.from_address).first || @message.from_address,
      to: MailHeaderEncoding.bare_addresses(@message.to_address),
      cc: @message.cc_address.present? ? MailHeaderEncoding.bare_addresses(@message.cc_address) : [],
      bcc: @message.bcc_address.present? ? MailHeaderEncoding.bare_addresses(@message.bcc_address) : [],
      subject: @message.subject,
      text_body: @message.body_plain,
      # Pixel-injected HTML for ESPs that send the structured field (raw_mime below
      # is injected too — same memoized token).
      html_body: tracked_html,
      raw_mime: compose_rfc5322,
      headers: {}
    ).tap do |ctx|
      # Honour suppression filtering: send only to the allowed recipients.
      allowed = recipients.map(&:downcase)
      ctx.to = ctx.to.select { |a| allowed.include?(a.downcase) }
      ctx.cc = ctx.cc.select { |a| allowed.include?(a.downcase) }
      ctx.bcc = ctx.bcc.select { |a| allowed.include?(a.downcase) }
    end
  end

  # DKIM d= must equal the From domain. Use the From address's domain when it is
  # one the org owns; otherwise fall back to the org's primary domain.
  def dkim_domain
    from = MailHeaderEncoding.bare_addresses(@message.from_address).first || @message.from_address.to_s
    host = from.split("@").last&.downcase
    return host if host.present? && @organization.domains.exists?(name: host)

    @organization.default_domain&.name
  end

  # Marks the delivery failed because every recipient is suppressed — nothing is
  # queued to NATS. Notifies the sender/assignees like any other failure.
  def mark_suppressed!(delivery_status, recipients)
    delivery_status.update!(
      status: DeliveryStatus::STATUS_FAILED,
      failed_at: Time.current,
      dsn_diagnostic: "suppressed: #{recipients.join(', ')}"
    )
    Rails.logger.info("[OutboundMailPublisher] All recipients suppressed for #{@message.key}: #{recipients.join(', ')}")
  end

  def build_payload(delivery_status, channel, recipients = nil)
    recipients ||= build_recipient_list

    payload = {
      version: 1,
      delivery_status_id: delivery_status.id,
      delivery_status_key: delivery_status.key,
      message_key: @message.key,
      envelope: {
        # The Go sender passes these verbatim to MAIL FROM / RCPT TO, so they
        # must be bare addr-specs, never `Name <addr>` mailboxes.
        mail_from: MailHeaderEncoding.bare_addresses(@message.from_address).first || @message.from_address,
        rcpt_to: recipients
      },
      dkim: {
        # Central platform key signs with d=<sending domain> (CNAME-delegated
        # DKIM; see DkimKey). d= must match the From domain, so derive it from the
        # From address (falls back to the org's primary domain).
        domain: dkim_domain,
        selector: DkimKey.selector,
        private_key_pem: DkimKey.private_key_pem.to_s
      },
      channel: {
        kind: channel.kind,
        delivery_channel_id: channel.id
      }
    }

    # Sealed rows (docs/E2EE.md Phase I): the durable queue gets the MIME
    # sealed to the MTA delivery key, never plaintext. Plaintext rows compose
    # here exactly as before.
    if @message.sealed?
      raise "sealed message #{@message.key} has no sealed_mime — cannot deliver" if @message.sealed_mime.blank?

      payload[:sealed_mime] = JSON.parse(@message.sealed_mime).slice("sealed_dek", "nonce", "ciphertext")
    else
      payload[:rfc5322_b64] = Base64.strict_encode64(compose_rfc5322)
    end

    payload
  end

  def compose_rfc5322
    attachments = (@attachments || @message.attachments).to_a
    # A meeting-invite RSVP (docs/Meeting-Invites.md) rides as a
    # `text/calendar; method=REPLY` part so the organizer's client records the
    # response — it forces the multipart/mixed wrapper even with no files.
    calendar_reply = @message.calendar_reply.presence
    has_attachments = attachments.any? || calendar_reply.present?

    # Headers must be ASCII-only (RFC 5322) — non-ASCII display names and
    # subjects are RFC 2047 encoded or they arrive as mojibake.
    lines = []
    lines << "From: #{MailHeaderEncoding.encode_address_header(@message.from_address)}"
    lines << "To: #{MailHeaderEncoding.encode_address_header(@message.to_address)}"
    lines << "Cc: #{MailHeaderEncoding.encode_address_header(@message.cc_address)}" if @message.cc_address.present?
    lines << "Subject: #{MailHeaderEncoding.encode_text(@message.subject || '(no subject)')}"
    lines << "Date: #{(@message.created_at || Time.current).rfc2822}"  # pre-save compose (sealed flow) has no created_at yet
    lines << "Message-ID: #{@message.message_id_header}" if @message.message_id_header.present?
    lines << "In-Reply-To: #{@message.in_reply_to}" if @message.in_reply_to.present?
    lines << "References: #{@message.references_header}" if @message.references_header.present?
    # A message submitted by a mail client keeps the Reply-To its sender set
    # (MailClient::Submit stores the client's header block).
    if @message.raw_headers.present? && (reply_to = Mail.new(@message.raw_headers)[:reply_to]&.value).present?
      lines << "Reply-To: #{MailHeaderEncoding.encode_address_header(reply_to)}"
    end
    lines << "MIME-Version: 1.0"
    # RFC 3834: an automatic reply must say so, or the far side's own
    # auto-responder answers it and the two servers mail each other forever.
    # X-Auto-Response-Suppress is the Microsoft-stack equivalent.
    if @message.auto_submitted.present?
      lines << "Auto-Submitted: #{@message.auto_submitted}"
      lines << "X-Auto-Response-Suppress: All"
      lines << "Precedence: auto_reply"
    end

    # No List-Unsubscribe here. It used to go on every message, which told the
    # receiver that a person's own mail was list mail: Gmail filed a first
    # message from a new domain as spam (2026-11-11, pfase.com, with SPF, DKIM
    # and DMARC all passing), and auto-responders stay silent for list mail.
    # ListUnsubscribeService stays for mail that really is a list (spec 18.4.2);
    # nothing inbox2 sends today is one.

    if has_attachments
      # multipart/mixed wraps the body + attachment parts
      mixed_boundary = "inbox2-mixed-#{SecureRandom.hex(16)}"
      lines << "Content-Type: multipart/mixed; boundary=\"#{mixed_boundary}\""
      lines << ""

      # Body part
      lines << "--#{mixed_boundary}"
      append_body_part(lines)

      # Attachment parts
      s3 = S3StorageService.new
      attachments.each do |att|
        lines << "--#{mixed_boundary}"
        # RFC 2231 extended parameters (`filename*=UTF-8''...`) — an RFC 2047
        # encoded-word is not valid syntax inside a parameter value.
        lines << "Content-Type: #{att.content_type || 'application/octet-stream'}; #{MailHeaderEncoding.encode_param('name', att.filename)}"
        lines << "Content-Disposition: attachment; #{MailHeaderEncoding.encode_param('filename', att.filename)}"
        lines << "Content-Transfer-Encoding: base64"
        lines << ""

        if att.storage_key.present?
          begin
            data = s3.download(att.storage_key)
            lines << Base64.strict_encode64(data).scan(/.{1,76}/).join("\r\n")
            Rails.logger.info("[OutboundMailPublisher] Attached #{att.key} (#{att.filename}, #{att.size_bytes} bytes) to message #{@message.key}")
          rescue => e
            Rails.logger.error("[OutboundMailPublisher] Failed to download attachment #{att.key} from S3: #{e.message}")
          end
        else
          Rails.logger.warn("[OutboundMailPublisher] Attachment #{att.key} has no storage_key, skipping")
        end
      end

      if calendar_reply
        # The method= parameter is what Outlook/Google read to decide whether
        # this is an invitation, a cancellation or an RSVP (an attached .ics
        # without it is often ignored). It must match the METHOD inside the
        # body, so it is read from there rather than assumed — the same column
        # now carries REQUEST and CANCEL as well as REPLY.
        lines << "--#{mixed_boundary}"
        lines << "Content-Type: text/calendar; method=#{calendar_method(calendar_reply)}; charset=UTF-8; name=\"invite.ics\""
        lines << "Content-Transfer-Encoding: base64"
        lines << ""
        lines << Base64.strict_encode64(calendar_reply).scan(/.{1,76}/).join("\r\n")
      end

      lines << "--#{mixed_boundary}--"
    else
      append_body_part(lines)
    end

    lines.join("\r\n")
  end

  # METHOD out of the iCalendar body; REPLY keeps the historical default for
  # any row written before invitations could be sent.
  def calendar_method(ics)
    ics[/^METHOD:([A-Z]+)/, 1] || "REPLY"
  end

  def append_body_part(lines)
    html = tracked_html
    if html.present?
      boundary = "inbox2-alt-#{SecureRandom.hex(16)}"
      lines << "Content-Type: multipart/alternative; boundary=\"#{boundary}\""
      lines << ""
      lines << "--#{boundary}"
      append_text_part(lines, "text/plain", @message.body_plain || "")
      lines << "--#{boundary}"
      append_text_part(lines, "text/html", html)
      lines << "--#{boundary}--"
    else
      append_text_part(lines, "text/plain", @message.body_plain || "")
    end
  end

  # The HTML body with the open-tracking pixel injected, when the sending domain
  # has open tracking on (docs/Open-Tracking.md). Memoized so the token is stable
  # across the multipart build, the raw MIME, and the ESP html_body field. The
  # token is persisted on the message so a later pixel hit correlates back.
  def tracked_html
    return @tracked_html if defined?(@tracked_html)

    # Plain-only senders (mobile) get an HTML alternative built here, so every
    # outbound mail ships both parts regardless of which client composed it.
    html = @message.body_html.presence || PlainBodyHtml.call(@message.body_plain)
    unless html.present? && (open_tracking_enabled? || link_tracking_enabled?)
      return @tracked_html = html
    end

    token = ensure_tracking_token
    # Rewrite links first (operates on <a href>), then append the open pixel.
    html = Tracking.rewrite_links(html, host: tracking_host) { |url| tracked_link_token(url, token) } if link_tracking_enabled?
    html = Tracking.inject(html, token, host: tracking_host) if open_tracking_enabled?
    @tracked_html = html
  end

  # The message's stable tracking token (shared by the open pixel + its links),
  # generated + persisted on first use. Sealed pre-save compose sets it in-memory;
  # the controller's later message.save persists it.
  def ensure_tracking_token
    token = @message.tracking_token.presence
    return token if token

    token = Tracking.token
    if @message.persisted?
      @message.update_column(:tracking_token, token)
    else
      @message.tracking_token = token
    end
    token
  end

  # The click token for one URL in this message (creates/reuses a TrackedLink row).
  # HTML-unescape so the stored redirect target is the real URL (hrefs carry &amp;).
  def tracked_link_token(url, msg_token)
    TrackedLink.for(
      message_tracking_token: msg_token,
      url: CGI.unescapeHTML(url.to_s),
      organization_id: @organization.id
    ).token
  end

  # The Domain the From-address belongs to (nil for external From). Sealed rows
  # null from_address AFTER compose, so this resolves at compose time as expected.
  def sending_domain
    return @sending_domain if defined?(@sending_domain)

    from = MailHeaderEncoding.bare_addresses(@message.from_address).first || @message.from_address.to_s
    host = from.split("@").last&.downcase
    @sending_domain = host.present? ? @organization.domains.find_by(name: host) : nil
  end

  def open_tracking_enabled?
    !!sending_domain&.open_tracking_enabled
  end

  def link_tracking_enabled?
    !!sending_domain&.link_tracking_enabled
  end

  def tracking_host
    sending_domain&.tracking_host || Tracking::DEFAULT_HOST
  end

  def append_text_part(lines, content_type, body)
    lines << "Content-Type: #{content_type}; charset=\"UTF-8\""
    lines << "Content-Transfer-Encoding: quoted-printable"
    lines << ""
    lines << quoted_printable(body)
  end

  # Quoted-printable encode a text body: 7-bit clean, lines within the SMTP
  # 998-char limit (HTML bodies are one giant line otherwise), CRLF endings.
  def quoted_printable(text)
    [text.to_s.gsub("\r\n", "\n")].pack("M").gsub("\n", "\r\n").chomp("\r\n")
  end

  def build_recipient_list
    recipients = MailHeaderEncoding.bare_addresses(@message.to_address)
    recipients += MailHeaderEncoding.bare_addresses(@message.cc_address) if @message.cc_address.present?
    # Bcc rides the envelope only — `compose_rfc5322` deliberately emits no Bcc
    # header, so the blind recipients stay invisible to everyone on the message.
    recipients += MailHeaderEncoding.bare_addresses(@message.bcc_address) if @message.bcc_address.present?
    recipients.reject(&:blank?)
  end

  def extract_domain(address)
    return "unknown" if address.blank?
    address.split("@").last&.downcase&.strip || "unknown"
  end

  def connect_nats
    config = nats_config
    NATS.connect(config["url"])
  end

  # nats-pure names this `find_stream_name_by_subject`; calling the wrong name
  # raised NoMethodError *past* the NotFound rescue below, so the stream was
  # never created and every outbound publish failed (prod, 2026-09-09).
  def ensure_stream(js)
    js.find_stream_name_by_subject("#{SUBJECT_PREFIX}>")
  rescue NATS::JetStream::Error::NotFound
    js.add_stream(
      name: STREAM_NAME,
      subjects: ["#{SUBJECT_PREFIX}>"],
      retention: "workqueue",
      max_age: 72 * 3600 * 1_000_000_000,
      max_bytes: 10 * 1024 * 1024 * 1024,
      storage: "file",
      discard: "old"
    )
  end

  def nats_config
    config_path = Rails.root.join("config", "nats.yml")
    config = YAML.safe_load(ERB.new(File.read(config_path)).result, aliases: true)
    config.fetch(Rails.env, config.fetch("default", {}))
  end
end
