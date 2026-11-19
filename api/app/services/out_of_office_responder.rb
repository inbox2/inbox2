# Sends the "I'm away" automatic reply when mail arrives for someone whose
# out-of-office period covers now (docs/Calendar.md).
#
# Almost all of this file is about NOT sending. An auto-responder that answers
# the wrong thing is not a cosmetic bug: reply to another auto-reply and the two
# servers will happily mail each other until someone notices; reply to a mailing
# list and the whole list gets it; reply to a bounce and the bounce bounces.
# RFC 3834 is the rulebook and it is followed deliberately here.
#
# MX-only. Sealed (E2EE) domains keep no server-side plaintext sender, so there
# is nobody to answer — those are skipped.
class OutOfOfficeResponder
  # RFC 3834: anything already automatic must never be answered. Only
  # "Auto-Submitted: no" (or an absent header) means "a human sent this".
  AUTO_SUBMITTED_HUMAN = "no".freeze

  # Legacy but still widely used: Precedence, and the list headers that mark
  # mail as coming from a distribution mechanism rather than a person.
  BULK_PRECEDENCE = %w[bulk list junk auto_reply].freeze
  LIST_HEADERS = %w[list-id list-unsubscribe list-post list-help list-subscribe].freeze

  # Microsoft's opt-out header. "OOF" is literally "out of facility" — a sender
  # asking not to receive exactly this.
  SUPPRESS_PATTERN = /\b(all|oof|autoreply|dr|rn|nrn)\b/i

  # Addresses that never want a reply, whatever else the headers say.
  ROBOT_LOCAL_PARTS = /\A(mailer-daemon|postmaster|no-?reply|do-?not-reply|noreply|bounces?|
                          notifications?|automated|daemon)\b/xi

  DEFAULT_MESSAGE = "I'm currently out of the office and will reply when I'm back.".freeze

  # `raw_mime` is the decoded RFC 5322 source; headers we need (Auto-Submitted,
  # Precedence, List-*) are not in the MX's fixed header set, so they are read
  # from the source rather than assumed absent.
  def self.maybe_reply(organization:, domain:, message:, envelope:, raw_mime:, recipient_local_part:)
    new(organization, domain, message, envelope, raw_mime, recipient_local_part).call
  end

  def initialize(organization, domain, message, envelope, raw_mime, recipient_local_part)
    @organization = organization
    @domain = domain
    @message = message
    @envelope = envelope || {}
    @raw_mime = raw_mime
    @recipient_local_part = recipient_local_part.to_s.downcase.presence
  end

  # Returns the sent reply Message, or nil (the overwhelmingly common case).
  def call
    return nil if @recipient_local_part.blank?

    mailbox = @domain&.mailboxes&.find_by(local_part: @recipient_local_part)
    user = mailbox&.membership&.user
    return nil unless user&.out_of_office?(@message.created_at || Time.current)
    return nil if sender.blank? || suppressed?

    # Claim before sending: a duplicate row is harmless, a duplicate reply is a
    # loop. The unique index is what actually arbitrates concurrent deliveries.
    unless OutOfOfficeReply.claim(user: user, organization: @organization,
                                  sender: sender, period_start: user.out_of_office_start)
      return nil
    end

    send_reply(mailbox, user)
  rescue StandardError => e
    # Never let the auto-responder fail the inbound pipeline — the mail itself
    # has already been stored and must not be redelivered over this.
    Rails.logger.warn("[OutOfOfficeResponder] #{e.class}: #{e.message}")
    nil
  end

  private

  def sender
    @sender ||= @message.from_address.to_s[/[\w.+-]+@[\w.-]+\.\w+/]&.downcase
  end

  def recipient_address
    "#{@recipient_local_part}@#{@domain.name}".downcase
  end

  # Every reason not to answer, in one place.
  def suppressed?
    return true if bounce?
    return true if already_automatic?
    return true if bulk_or_list?
    return true if suppress_requested?
    return true if robot_sender?
    return true if self_addressed?
    return true if spam?

    false
  end

  # A DSN carries an empty envelope sender precisely so replies stop here.
  def bounce?
    mail_from = @envelope["mail_from"].to_s.strip
    return true if mail_from.blank? || mail_from == "<>"

    header("return-path").to_s.strip.delete("<>").empty? && header("return-path").present?
  end

  def already_automatic?
    value = header("auto-submitted").to_s.strip.downcase
    value.present? && !value.start_with?(AUTO_SUBMITTED_HUMAN)
  end

  def bulk_or_list?
    return true if LIST_HEADERS.any? { |h| header(h).present? }

    BULK_PRECEDENCE.include?(header("precedence").to_s.strip.downcase)
  end

  def suppress_requested?
    header("x-auto-response-suppress").to_s.match?(SUPPRESS_PATTERN)
  end

  def robot_sender?
    sender.to_s.split("@").first.to_s.match?(ROBOT_LOCAL_PARTS)
  end

  # Mail from the away person to themselves, or from another address on this
  # same mailbox — answering it achieves nothing and can ping-pong.
  def self_addressed?
    sender == recipient_address
  end

  def spam?
    @message.spam_action.present? && @message.spam_action != "no_action" ||
      @message.conversation&.status == Conversation::STATUS_SPAM
  end

  def header(name)
    parsed_headers[name.downcase]
  end

  # Parsed once from the raw source. The MX publishes only nine fixed headers,
  # so everything this class tests on has to come from here.
  def parsed_headers
    @parsed_headers ||= begin
      require "mail"
      mail = Mail.new(@raw_mime)
      mail.header.fields.each_with_object({}) do |field, acc|
        acc[field.name.to_s.downcase] ||= field.value.to_s
      end
    rescue StandardError => e
      Rails.logger.warn("[OutOfOfficeResponder] header parse failed: #{e.message}")
      {}
    end
  end

  def send_reply(mailbox, user)
    body = user.out_of_office_message.presence || DEFAULT_MESSAGE
    reply = @message.conversation.messages.create!(
      organization: @organization,
      from_address: recipient_address,
      to_address: sender,
      subject: "Automatic reply: #{@message.subject.presence || '(no subject)'}",
      body_plain: body,
      content_type: "text/plain",
      in_reply_to: @message.message_id_header,
      references_header: [@message.references_header, @message.message_id_header].compact.join(" ").presence,
      # Marks the wire copy per RFC 3834 so the far side does not answer back.
      auto_submitted: Message::AUTO_SUBMITTED_REPLIED,
      is_inbound: false,
      is_draft: false
    )
    OutboundDeliveryJob.perform_later(reply.id)
    Rails.logger.info("[OutOfOfficeResponder] replied to #{sender} for #{recipient_address}")
    reply
  end
end
