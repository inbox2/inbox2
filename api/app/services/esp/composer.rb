require "mail"

# Builds the RFC 5322 message for an API send. Bcc is envelope-only: it is
# never written into the message.
class Esp::Composer
  def initialize(message, text:, html:, headers: {}, attachments: [])
    @message = message
    @text = text.presence
    @html = html.presence
    @headers = headers
    @attachments = attachments
  end

  def call
    m = @message
    text = @text
    html = @html
    mail = Mail.new
    mail.charset = "UTF-8"
    mail.from = m.from_address
    mail.to = m.to_address
    mail.cc = m.cc_address if m.cc_address.present?
    mail.reply_to = m.reply_to if m.reply_to.present?
    mail.subject = m.subject
    mail.date = Time.current
    mail.message_id = m.message_id_header
    @headers.each { |name, value| mail[name] = value }

    if text && html
      mail.text_part = Mail::Part.new { content_type "text/plain; charset=UTF-8"; body text }
      mail.html_part = Mail::Part.new { content_type "text/html; charset=UTF-8"; body html }
    elsif html
      mail.content_type = "text/html; charset=UTF-8"
      mail.body = html
    else
      mail.content_type = "text/plain; charset=UTF-8"
      mail.body = text
    end
    @attachments.each do |att|
      mail.attachments[att[:filename]] = { content: att[:content], mime_type: att[:content_type] }.compact
    end
    mail.encoded
  end
end
