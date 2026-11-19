# Builds one organisation data export (spec 11.3.3, A15.6): a single .zip with
#
#   <domain>/mail.mbox        every non-draft message of the domain's threads (mboxrd)
#   calendars/<name>-<key>.ics one VCALENDAR per calendar, recurrence rules included
#   README.txt                what's inside, counts, how to import
#
# inbox2 doesn't keep the raw MIME of plaintext mail, so each message is rebuilt
# from its stored headers, bodies and attachments with the `mail` gem. Sealed
# (e2ee) messages go in as stored: ciphertext only, never decrypted here.
#
# Everything streams: messages come in batches and are written straight into the
# zip entry on disk, then the file is uploaded to object storage.
require "mail"

class DataExportJob < ApplicationJob
  queue_as :default
  discard_on ActiveJob::DeserializationError

  NO_DOMAIN_FOLDER = "other".freeze
  BATCH_SIZE = 200

  def perform(export_id)
    @export = DataExport.find_by(id: export_id)
    return unless @export&.status == DataExport::STATUS_QUEUED

    @export.update!(status: DataExport::STATUS_RUNNING)
    @org = @export.organization
    @counts = Hash.new(0)
    @generated_at = Time.current

    file = Tempfile.new(["export", ".zip"], binmode: true)
    begin
      Zip::OutputStream.open(file.path) do |zip|
        write_mail(zip)
        write_calendars(zip)
        zip.put_next_entry("README.txt")
        zip.write(readme)
      end

      key = File.open(file.path, "rb") do |io|
        storage.upload(io, filename: @export.filename, content_type: "application/zip", organization_key: @org.key)
      end
      @export.update!(status: DataExport::STATUS_READY, storage_key: key, byte_size: File.size(file.path),
                      counts: @counts, expires_at: Time.current + DataExport::RETENTION, error: nil)
    rescue StandardError => e
      Rails.logger.error("[DataExportJob] #{@export.key} failed: #{e.class}: #{e.message}")
      @export.update!(status: DataExport::STATUS_FAILED, error: e.message.to_s.truncate(500), counts: @counts)
    ensure
      file.close!
    end
  end

  private

  def storage
    @storage ||= S3StorageService.new
  end

  # ── Mail ──────────────────────────────────────────────────────────────

  def write_mail(zip)
    @org.domains.order(:name).each do |domain|
      @counts["domains"] += 1
      write_mbox(zip, "#{safe_name(domain.name)}/mail.mbox", domain.id)
    end
    # Threads that never got a domain (pre-domain imports) still belong in the export.
    return unless @org.conversations.where(domain_id: nil).exists?

    write_mbox(zip, "#{NO_DOMAIN_FOLDER}/mail.mbox", nil)
  end

  def write_mbox(zip, path, domain_id)
    zip.put_next_entry(path)
    # Imported history and personal mailboxes are private to their member —
    # not in the pool, not in the admin's export (docs/plans/mail-import.md).
    @org.messages.where(is_draft: false)
        .where(conversation_id: @org.conversations.org_readable.where(domain_id: domain_id).select(:id))
        .includes(:attachments)
        .find_each(batch_size: BATCH_SIZE) do |message|
      raw = message.sealed? ? sealed_mime(message) : rebuilt_mime(message)
      zip.write(mbox_entry(envelope_sender(message), message.created_at, raw))
      @counts["messages"] += 1
      @counts["sealed_messages"] += 1 if message.sealed?
    rescue StandardError => e
      Rails.logger.warn("[DataExportJob] skipped #{message.key}: #{e.class}: #{e.message}")
      @counts["messages_failed"] += 1
    end
  end

  def rebuilt_mime(message)
    mail = Mail.new
    mail.charset = "UTF-8"
    mail.from = message.from_address
    mail.to = message.to_address if message.to_address.present?
    mail.cc = message.cc_address if message.cc_address.present?
    mail.bcc = message.bcc_address if message.bcc_address.present?
    mail.subject = message.subject.to_s
    mail.date = message.created_at
    mail.message_id = message.message_id_header if message.message_id_header.present?
    mail.in_reply_to = message.in_reply_to if message.in_reply_to.present?
    mail.references = message.references_header if message.references_header.present?
    mail["X-Inbox2-Id"] = message.key

    body = body_part(message)
    files = message.attachments.filter_map { |a| (data = fetch_attachment(a)) && [a, data] }
    if files.empty?
      mail.content_type = body.content_type
      body.multipart? ? body.parts.each { |part| mail.add_part(part) } : mail.body = body.body.decoded
    else
      mail.content_type = "multipart/mixed"
      mail.add_part(body)
      files.each do |attachment, data|
        mail.attachments[attachment.filename.presence || attachment.key] =
          { mime_type: attachment.content_type.presence || "application/octet-stream", content: data }
      end
    end
    mail.to_s
  end

  # text/plain, text/html, or multipart/alternative of both.
  def body_part(message)
    plain = Mail::Part.new(content_type: "text/plain; charset=UTF-8", body: message.body_plain.to_s)
    return plain if message.body_html.blank?

    html = Mail::Part.new(content_type: "text/html; charset=UTF-8", body: message.body_html)
    return html if message.body_plain.blank?

    Mail::Part.new(content_type: "multipart/alternative").tap do |alt|
      alt.add_part(plain)
      alt.add_part(html)
    end
  end

  # Sealed rows carry their headers and body as ciphertext only. Export that as
  # stored (JSON part) plus each attachment's ciphertext; the domain key holder
  # can decrypt it, the server can't and doesn't try.
  def sealed_mime(message)
    mail = Mail.new
    mail.from = "sealed@#{@org.default_domain&.name || 'inbox2.invalid'}"
    mail.subject = "Sealed message #{message.key}"
    mail.date = message.created_at
    mail.message_id = message.message_id_header if message.message_id_header.present?
    mail["X-Inbox2-Id"] = message.key
    mail["X-Inbox2-Encryption"] = message.encryption_scheme
    mail.content_type = "multipart/mixed"
    mail.add_part Mail::Part.new(
      content_type: "text/plain; charset=UTF-8",
      body: "This message is end-to-end encrypted. inbox2 can't read it, so it's exported as ciphertext in sealed.json. See README.txt."
    )
    fields = message.slice(:encryption_scheme, :domain_key_version, :sealed_dek, :seal_aad, :header_ciphertext,
                           :header_nonce, :body_ciphertext, :body_nonce, :sealed_mime).compact
    mail.attachments["sealed.json"] = { mime_type: "application/json", content: JSON.pretty_generate(fields) }
    message.attachments.each do |attachment|
      data = fetch_attachment(attachment)
      mail.attachments["#{attachment.key}.sealed"] = { mime_type: "application/octet-stream", content: data } if data
    end
    mail.to_s
  end

  def fetch_attachment(attachment)
    @counts["attachments"] += 1
    raise ArgumentError, "no stored content" if attachment.storage_key.blank?

    storage.download(attachment.storage_key)
  rescue StandardError => e
    Rails.logger.warn("[DataExportJob] attachment #{attachment.key} unavailable: #{e.class}")
    @counts["attachments"] -= 1
    @counts["attachments_missing"] += 1
    nil
  end

  # mboxrd (RFC 4155): a "From " separator line, LF line endings, and any body
  # line starting with ">*From " quoted with one more ">".
  def mbox_entry(sender, time, raw)
    out = +"From #{sender} #{time.utc.asctime}\n"
    raw.gsub("\r\n", "\n").each_line { |line| out << (line.match?(/\A>*From /) ? ">#{line}" : line) }
    out << "\n" unless out.end_with?("\n")
    out << "\n"
  end

  def envelope_sender(message)
    message.from_address.to_s[/[^<>\s"]+@[^<>\s"]+/] || "MAILER-DAEMON"
  end

  # ── Calendars ─────────────────────────────────────────────────────────

  def write_calendars(zip)
    @org.calendars.order(:created_at).each do |calendar|
      @counts["calendars"] += 1
      zip.put_next_entry("calendars/#{safe_name(calendar.name)}-#{calendar.key}.ics")
      zip.write("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//inbox2//export//EN\r\nCALSCALE:GREGORIAN\r\n" \
                "X-WR-CALNAME:#{IcsReply.escape(calendar.name)}\r\n")
      calendar.calendar_events.includes(:attendees).find_each(batch_size: BATCH_SIZE) do |event|
        zip.write(vevent(event))
        @counts["events"] += 1
      end
      zip.write("END:VCALENDAR\r\n")
    end
  end

  # Reuse the invitation builder for the VEVENT itself (UID, RRULE,
  # RECURRENCE-ID, attendees) and keep just that block. CANCEL is what makes a
  # cancelled occurrence override come out as STATUS:CANCELLED.
  def vevent(event)
    method = event.status == CalendarEvent::STATUS_CANCELLED ? IcsRequest::METHOD_CANCEL : IcsRequest::METHOD_REQUEST
    ics = IcsRequest.build(event, organizer_email: event.organizer_email.presence || "calendar@#{@org.default_domain&.name || 'inbox2.invalid'}",
                                  organizer_name: event.organizer_name, method: method, now: @generated_at)
    ics[/BEGIN:VEVENT\r\n.*END:VEVENT\r\n/m]
  end

  # ── README ────────────────────────────────────────────────────────────

  def readme
    <<~TXT
      inbox2 data export for #{@org.name}
      Generated #{@generated_at.utc.iso8601}

      What's inside
        <domain>/mail.mbox    All mail for that domain, one mbox file per domain (#{count('messages', 'message')} across #{count('domains', 'domain')}).
        #{NO_DOMAIN_FOLDER}/mail.mbox     Mail that isn't tied to a domain, if there is any.
        calendars/*.ics       One file per calendar (#{count('calendars', 'calendar')}, #{count('events', 'event')}). Repeating events keep their rules.

      Attachments are inside the messages (#{@counts['attachments']} included, #{@counts['attachments_missing']} could not be fetched).
      Drafts are not included.#{@counts['messages_failed'].positive? ? " #{count('messages_failed', 'message')} could not be exported." : ''}

      Encrypted mail
        End-to-end encrypted: #{count('sealed_messages', 'message')}. inbox2 never holds the key to read them,
        so they are exported as stored: the ciphertext sits in a sealed.json attachment on each one,
        next to the encrypted attachments. Only your domain's key can open them.

      Importing
        Apple Mail: File > Import Mailboxes, pick "Files in mbox format", choose the mail.mbox file.
        Thunderbird: install the ImportExportTools NG add-on, then Tools > ImportExportTools NG > Import mbox file.
        Calendars: every calendar app imports .ics. In Google Calendar go to Settings > Import & export.
        In Apple Calendar use File > Import. In Outlook use File > Open & Export > Import/Export.

      This download expires 7 days after it was made.
    TXT
  end

  def count(key, word)
    n = @counts[key]
    "#{n} #{word.pluralize(n)}"
  end

  def safe_name(name)
    name.to_s.gsub(/[^\w.\-@ ]/, "_").strip.presence || "untitled"
  end
end
