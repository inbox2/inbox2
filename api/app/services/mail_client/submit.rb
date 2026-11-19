require "mail"

# A message a mail client hands over to be sent (SMTP submission). It becomes
# an ordinary sent message in the person's own mail and goes out through the
# normal outbound pipeline, so delivery status, retries and suppression all
# work as for a send from inbox2's own clients.
module MailClient
  class Submit
    def initialize(membership, mail_from:, rcpt_to:, raw:)
      @membership = membership
      @org = membership.organization
      @mail_from = mail_from.to_s.strip
      @rcpt_to = Array(rcpt_to).map { |a| a.to_s.strip.downcase }.reject(&:blank?).uniq
      @raw = raw.to_s
    end

    def call
      mail = Mail.new(@raw)
      from = mail[:from]&.value.to_s.presence || @mail_from
      from_addrs = MailHeaderEncoding.bare_addresses(from)
      # The whole From header goes out as written, so it may name one sender only.
      refuse("A message must have exactly one From address") unless from_addrs.size == 1
      from_addr = from_addrs.first.to_s.downcase
      refuse("A message needs a recipient") if @rcpt_to.empty?
      # Both the envelope sender and the From header must be the person's own.
      [@mail_from, from_addr].each { |a| refuse("You can't send as #{a}", status: 403) unless @membership.can_send_as?(a) }
      if OutboundMessageSealer.sealing_domain(@org, from_addr)
        refuse("#{from_addr.split('@').last} is a sealed domain; send from an inbox2 app", status: 403)
      end

      message_id = mail.message_id.present? ? "<#{mail.message_id}>" : "<#{SecureRandom.uuid}@#{from_addr.split('@').last}>"
      # A client that lost our answer sends again: answer, do not send twice.
      # Only the person's own earlier send counts, and it is queued again if
      # the first try never got that far.
      if (existing = @org.messages.find_by(message_id_header: message_id, is_inbound: false, sender_membership_id: @membership.id))
        OutboundDeliveryJob.perform_later(existing.id)
        return existing
      end
      refuse("This Message-ID is already in use") if @org.messages.exists?(message_id_header: message_id, owner_membership_id: nil)

      attachments = mail.attachments.to_a
      if attachments.sum { |a| a.decoded.bytesize } > OutboundMailPublisher::MAX_ATTACHMENT_BYTES
        refuse("Attachments add up to more than #{OutboundMailPublisher::MAX_ATTACHMENT_BYTES / 1.megabyte} MB")
      end
      if (denied = SendQuota.new(@org).deny_reason(recipients: @rcpt_to.size))
        refuse(denied, status: 429)
      end

      to = mail[:to]&.value.to_s
      cc = mail[:cc]&.value.to_s
      named = (MailHeaderEncoding.bare_addresses(to) + MailHeaderEncoding.bare_addresses(cc)).map(&:downcase)
      # The pipeline mails everyone in To, Cc and Bcc. So the headers may name
      # only people the client put in the envelope: with that, the three
      # together are exactly the envelope, which is what the quota counted.
      extra = named.uniq - @rcpt_to
      refuse("To and Cc name #{extra.first}, who is not an envelope recipient") if extra.any?
      bcc = @rcpt_to - named
      text, html = bodies(mail)

      # Stored before anything is committed: a failed upload leaves no message
      # behind, so the client's retry starts clean.
      stored = store_attachments(attachments)
      message = nil
      Conversation.transaction do
        conversation = thread_for(mail) || @org.conversations.create!(
          subject: mail.subject, from_address: from, to_address: to.presence || bcc.join(", "),
          status: Conversation::STATUS_OPEN, domain: @org.domains.find_by(name: from_addr.split("@").last),
          # The sender's own thread, whatever address they sent as: a send-as
          # address has no mailbox to stamp it by, and an unstamped thread
          # would be the team's, gone from this person's Sent folder.
          personal_membership_id: @membership.id
        )
        message = conversation.messages.create!(
          organization: @org, from_address: from, to_address: to.presence, cc_address: cc.presence,
          bcc_address: bcc.join(", ").presence, subject: mail.subject || conversation.subject,
          body_plain: text, body_html: html, content_type: html ? "text/html" : "text/plain",
          is_inbound: false, is_draft: false, sender_membership_id: @membership.id,
          message_id_header: message_id, in_reply_to: header_ids(mail, :in_reply_to).first,
          references_header: header_ids(mail, :references).join(" ").presence,
          raw_headers: Mime.header_block(@raw), calendar_reply: calendar_part(mail, attachments)
        )
        stored.each { |att| Attachment.create!(att.merge(message: message, organization: @org)) }
        if conversation.personal_membership_id && conversation.personal_membership_id != @membership.id
          ConversationAccess.find_or_create_by!(conversation: conversation, membership: @membership)
        end
        # A reply to a thread in Trash takes the thread out of it, or the sent
        # message would be filed in Trash and not in Sent.
        conversation.status = Conversation::STATUS_OPEN if conversation.status == Conversation::STATUS_TRASH
        conversation.update!(snippet: SnippetBuilder.build(text, html),
          triage_label: TriageLabel::WAITING_REPLY, triage_source: TriageLabel::SOURCE_RULE_SENT)
      end
      # No undo window: the mail client has already shown the message as sent.
      # The job skips a message that is already queued, so a replay is safe.
      OutboundDeliveryJob.perform_later(message.id)
      message
    end

    private

    def refuse(message, status: 422) = raise(Refused.new(message, status: status))

    def bodies(mail)
      text = (mail.multipart? ? mail.text_part : (mail unless mail.mime_type == "text/html"))
      html = (mail.multipart? ? mail.html_part : (mail if mail.mime_type == "text/html"))
      [decode(text), decode(html)]
    end

    # An invitation or a reply to one, sent inline (not as a file). The
    # publisher sends `calendar_reply` out again as a text/calendar part.
    def calendar_part(mail, attachments)
      part = mail.all_parts.find { |p| p.mime_type == "text/calendar" && attachments.exclude?(p) }
      decode(part)
    end

    def decode(part)
      return nil unless part

      body = part.decoded.to_s
      body = body.dup.force_encoding(part.charset.presence || "UTF-8") rescue body
      body.encode("UTF-8", invalid: :replace, undef: :replace).delete("\u0000").presence
    end

    def header_ids(mail, field)
      mail[field]&.value.to_s.scan(/<[^>]+>/)
    end

    # A reply goes into the thread it answers, when that thread is the person's own.
    def thread_for(mail)
      ids = header_ids(mail, :in_reply_to) + header_ids(mail, :references).reverse
      return nil if ids.empty?

      parent = Message.joins(:conversation).merge(@org.conversations.personal_to(@membership))
        .where(message_id_header: ids).order(id: :desc).first
      parent&.conversation
    end

    # Uploads each attachment; returns the attributes of the rows to create.
    def store_attachments(attachments)
      s3 = S3StorageService.new if attachments.any?
      attachments.map do |att|
        data = att.decoded
        filename = att.filename.to_s.delete("\u0000").presence || "unnamed"
        key = s3.upload(data, filename: filename, content_type: att.mime_type, organization_key: @org.key)
        { filename: filename, content_type: att.mime_type, size_bytes: data.bytesize, storage_key: key }
      end
    end
  end
end
