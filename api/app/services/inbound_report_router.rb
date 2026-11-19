# Routes machine-generated mail reports — DSN bounces (RFC 3464), ARF feedback
# reports (RFC 5965), TLS-RPT aggregates (RFC 8460), and DMARC rua aggregates
# (RFC 7489) — instead of threading them as ordinary conversations.
#
# A bounce updates the originating DeliveryStatus (via DsnBounceParser) and, when
# the address is dead, adds it to the org suppression list. A complaint suppresses
# the complaining recipient so we stop mailing someone who flagged us as spam.
# TLS-RPT / DMARC aggregates become MailAuthReport rows (TODO 46.10) so our own
# auth/TLS failures as seen by receiving providers are stored and queryable.
#
# Returns :bounce / :complaint / :tlsrpt / :dmarc when it handled the message
# (caller skips normal processing), or nil when this isn't a report.
class InboundReportRouter
  MULTIPART_REPORT = "multipart/report".freeze
  DSN_REPORT = "delivery-status".freeze
  ARF_REPORT = "feedback-report".freeze
  TLSRPT_REPORT = "tlsrpt".freeze

  # Only match a report against sends from the recent past — a stale bounce
  # shouldn't mutate an unrelated, long-settled delivery.
  MATCH_WINDOW = 30.days

  def initialize(organization, raw_message, content_type_hint: nil)
    @org = organization
    @raw = raw_message.to_s
    @hint = content_type_hint.to_s
  end

  def route
    return nil if @raw.blank?

    require "mail"
    case report_type
    when DSN_REPORT then handle_bounce(Mail.new(@raw))
    when ARF_REPORT then handle_complaint(Mail.new(@raw))
    when TLSRPT_REPORT then handle_tlsrpt(Mail.new(@raw))
    else
      # DMARC rua aggregates are NOT multipart/report — plain mail with a
      # zip/gzip/xml attachment. Detected by content, not envelope.
      handle_dmarc_if_report(Mail.new(@raw))
    end
  rescue => e
    Rails.logger.warn("[InboundReportRouter] #{e.class}: #{e.message}")
    nil
  end

  private

  # report-type lives on the multipart/report Content-Type. Prefer the cheap
  # header hint; fall back to the parsed message.
  def report_type
    if @hint =~ /report-type=["']?([\w-]+)/i
      return Regexp.last_match(1).downcase
    end

    ct = @raw[/^Content-Type:\s*multipart\/report.*$/i]
    return Regexp.last_match(1).downcase if ct && ct =~ /report-type=["']?([\w-]+)/i

    nil
  end

  def handle_bounce(mail)
    dsn_text = part_body(mail, "message/delivery-status") || @raw
    parser = DsnBounceParser.new(dsn_text)
    result = parser.parse

    recipient = result[:original_recipient] || recipient_from_returned_headers(mail)
    delivery_status = match_delivery_status(recipient, returned_message_id(mail))

    if delivery_status
      parser.update_delivery_status!(delivery_status)
      Rails.logger.info("[InboundReportRouter] Bounce → #{delivery_status.key} (#{result[:bounce_type]}, #{result[:dsn_code]})")
    else
      Rails.logger.info("[InboundReportRouter] Bounce for #{recipient || 'unknown'} — no matching delivery status")
    end

    if result[:bounce_type] == DsnBounceParser::BOUNCE_HARD && recipient.present?
      SuppressionEntry.record!(@org, clean_address(recipient),
        reason: SuppressionEntry::REASON_HARD_BOUNCE, source: "dsn", detail: result[:diagnostic])
    end

    :bounce
  end

  def handle_complaint(mail)
    report = part_body(mail, "message/feedback-report").to_s
    complained = report[/^Original-Rcpt-To:\s*(?:rfc822;\s*)?(.+)$/i, 1]&.strip
    complained ||= recipient_from_returned_headers(mail)

    # A complaint about an API send settles that delivery too (docs/ESP.md).
    if complained.present? && (esp = esp_delivery_for(clean_address(complained), returned_message_id(mail)))
      esp.record_complaint!(report[/^Feedback-Type:\s*(.+)$/i, 1]&.strip)
    end

    if complained.present?
      SuppressionEntry.record!(@org, clean_address(complained),
        reason: SuppressionEntry::REASON_COMPLAINT, source: "arf", detail: report[/^Feedback-Type:\s*(.+)$/i, 1]&.strip)
      Rails.logger.info("[InboundReportRouter] Complaint → suppressed #{clean_address(complained)}")
    else
      Rails.logger.info("[InboundReportRouter] Complaint with no resolvable recipient")
    end

    :complaint
  end

  def esp_delivery_for(recipient, message_id)
    return nil if message_id.blank?

    Esp::Delivery.joins(:message).where(organization: @org, recipient: recipient.to_s.downcase)
      .where(esp_messages: { message_id_header: message_id }).first
  end

  # TLS-RPT aggregate (RFC 8460 §5.3): multipart/report; report-type=tlsrpt with
  # an application/tlsrpt+gzip or +json payload part.
  def handle_tlsrpt(mail)
    part = find_part(mail, "application/tlsrpt") || mail
    body = part.body&.decoded.to_s
    body = gunzip(body) if part.content_type.to_s.include?("gzip") || gzip?(body)
    store_report(TlsRptReportParser.new(body).attributes)
    :tlsrpt
  end

  # DMARC rua aggregate: a zip/gz/xml attachment whose XML root is <feedback>.
  def handle_dmarc_if_report(mail)
    xml = dmarc_xml(mail)
    return nil unless xml&.include?("<policy_published")

    store_report(DmarcReportParser.new(xml).attributes)
    :dmarc
  end

  # Finds and decompresses a DMARC-shaped attachment. Returns nil when none.
  def dmarc_xml(mail)
    parts = mail.multipart? ? mail.all_parts : [mail]
    parts.each do |part|
      ct = part.content_type.to_s
      raw = part.body&.decoded.to_s
      next if raw.blank?

      if ct.include?("zip") && !ct.include?("gzip")
        entry = unzip_first(raw)
        return entry if entry&.include?("<feedback")
      elsif ct.include?("gzip") || gzip?(raw)
        text = gunzip(raw)
        return text if text&.include?("<feedback")
      elsif ct.include?("xml") && raw.include?("<feedback")
        return raw
      end
    end
    nil
  end

  def store_report(attrs)
    # Reporters resend on failure — dedupe on (kind, reporter, report_id).
    if attrs[:report_id].present? &&
       @org.mail_auth_reports.exists?(kind: attrs[:kind], reporter: attrs[:reporter], report_id: attrs[:report_id])
      Rails.logger.info("[InboundReportRouter] Duplicate #{attrs[:kind]} report #{attrs[:report_id]} — skipped")
      return
    end
    report = @org.mail_auth_reports.create!(attrs)
    if report.failure_count.positive?
      Rails.logger.warn("[InboundReportRouter] #{report.kind} report from #{report.reporter}: " \
                        "#{report.failure_count}/#{report.total_count} FAILED for #{report.domain}")
    else
      Rails.logger.info("[InboundReportRouter] #{report.kind} report from #{report.reporter}: all #{report.total_count} passed")
    end
  end

  def gzip?(bytes)
    bytes.byteslice(0, 2)&.bytes == [0x1f, 0x8b]
  end

  def gunzip(bytes)
    Zlib::GzipReader.new(StringIO.new(bytes)).read
  rescue Zlib::Error
    bytes
  end

  def unzip_first(bytes)
    Zip::File.open_buffer(StringIO.new(bytes)) do |zip|
      entry = zip.entries.first
      return entry&.get_input_stream&.read
    end
  rescue Zip::Error
    nil
  end

  # Most recent outbound delivery whose recipient matches the bounced address, or
  # whose message carries the returned Message-ID.
  def match_delivery_status(recipient, message_id)
    scope = DeliveryStatus.joins(:message)
      .where(messages: { organization_id: @org.id, is_inbound: false })
      .where("delivery_statuses.created_at > ?", MATCH_WINDOW.ago)
      .order(created_at: :desc)

    addr = clean_address(recipient)

    if message_id.present?
      by_id = scope.where(messages: { message_id_header: message_id }).to_a
      # A message fans out to one row per destination, so pick the row whose
      # envelope actually held the bounced address before falling back.
      return by_id.find { |d| d.covers?(addr) } || by_id.first if by_id.any?
    end

    return nil if addr.blank?

    scope.where("delivery_statuses.recipients ILIKE ?", "%#{addr}%").first ||
      scope.where("messages.to_address ILIKE ?", "%#{addr}%").first
  end

  # The returned original message (message/rfc822 part) carries the headers we
  # sent — Message-ID and the To we addressed.
  def returned_message_id(mail)
    body = part_body(mail, "message/rfc822") || part_body(mail, "text/rfc822-headers")
    body&.[](/^Message-I[dD]:\s*(<[^>]+>)/, 1)
  end

  def recipient_from_returned_headers(mail)
    body = part_body(mail, "message/rfc822") || part_body(mail, "text/rfc822-headers")
    body&.[](/^To:\s*(.+)$/i, 1)&.strip
  end

  def part_body(mail, content_type)
    part = find_part(mail, content_type)
    part&.body&.decoded
  end

  def find_part(mail, content_type)
    return mail if mail.content_type.to_s.start_with?(content_type)

    mail.all_parts.find { |p| p.content_type.to_s.start_with?(content_type) } if mail.multipart?
  end

  def clean_address(value)
    return nil if value.blank?

    value[/<([^>]+)>/, 1] || value.strip.split(/\s+/).first
  end
end
