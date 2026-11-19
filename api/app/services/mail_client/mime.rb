# Rebuilds a stored message as RFC 5322 bytes for a mail client
# (docs/Mail-Clients.md). inbox2 keeps parsed fields, not the bytes that
# arrived, so the body is re-encoded here. It is built the same way every time
# (fixed boundaries, base64 throughout), so a message never changes under a
# client. When the original header block was kept (messages.raw_headers) the
# message carries its own headers, minus the ones that described the original
# body structure.
module MailClient
  class Mime
    # Headers that describe the body as it arrived; ours replace them.
    BODY_HEADERS = %w[mime-version content-type content-transfer-encoding content-disposition
                      content-id content-description content-language].freeze
    LINE = 76
    MAX_HEADER_BYTES = 64 * 1024

    # The header block of a raw message, as text Postgres will take.
    def self.header_block(raw)
      head = raw.to_s.b.split(/\r?\n\r?\n/, 2).first.to_s[0, MAX_HEADER_BYTES]
      head.force_encoding("UTF-8").scrub("?").delete("\u0000").presence
    end

    def initialize(message)
      @message = message
    end

    def header = "#{[*message_headers, *top[:headers]].join("\r\n")}\r\n\r\n"

    def raw
      out = +header
      write(top, out, fetch: true)
      out
    end

    # Exact length of `raw`, without fetching one attachment.
    def size
      out = +header
      extra = write(top, out, fetch: false)
      out.bytesize + extra
    end

    private

    def message_headers
      kept = @message.raw_headers.present? ? original_headers : []
      kept.presence || synthesized_headers
    end

    def original_headers
      fields = []
      @message.raw_headers.gsub("\r\n", "\n").each_line(chomp: true) do |line|
        break if line.empty?

        if line.start_with?(" ", "\t") && fields.any?
          fields.last << "\r\n" << line
        elsif line.include?(":")
          fields << +line
        end
      end
      fields.reject { |f| BODY_HEADERS.include?(f.split(":", 2).first.strip.downcase) }
    end

    def synthesized_headers
      m = @message
      [
        ("From: #{MailHeaderEncoding.encode_address_header(m.from_address)}" if m.from_address.present?),
        ("To: #{MailHeaderEncoding.encode_address_header(m.to_address)}" if m.to_address.present?),
        ("Cc: #{MailHeaderEncoding.encode_address_header(m.cc_address)}" if m.cc_address.present?),
        "Subject: #{MailHeaderEncoding.encode_text(m.subject.to_s)}",
        "Date: #{m.created_at.rfc2822}",
        ("Message-ID: #{m.message_id_header}" if m.message_id_header.present?),
        ("In-Reply-To: #{m.in_reply_to}" if m.in_reply_to.present?),
        ("References: #{m.references_header}" if m.references_header.present?)
      ].compact
    end

    # The body as a tree: { headers:, text: } | { headers:, attachment: } | { headers:, boundary:, parts: }
    def top
      @top ||= begin
        text = @message.body_plain.presence
        html = @message.body_html.presence
        content = if text && html
          multipart("alternative", [text_part("plain", text), text_part("html", html)])
        else
          html ? text_part("html", html) : text_part("plain", text.to_s)
        end
        attachments = @message.attachments.to_a
        node = attachments.any? ? multipart("mixed", [content, *attachments.map { |a| attachment_part(a) }]) : content
        node.merge(headers: ["MIME-Version: 1.0", *node[:headers]])
      end
    end

    def text_part(subtype, text)
      { headers: ["Content-Type: text/#{subtype}; charset=UTF-8", "Content-Transfer-Encoding: base64"], text: text }
    end

    def attachment_part(att)
      type = att.content_type.to_s.match?(%r{\A[\w.+-]+/[\w.+-]+\z}) ? att.content_type : "application/octet-stream"
      name = att.filename.presence || "unnamed"
      { headers: ["Content-Type: #{type}; #{MailHeaderEncoding.encode_param('name', name)}",
                  "Content-Disposition: attachment; #{MailHeaderEncoding.encode_param('filename', name)}",
                  "Content-Transfer-Encoding: base64"], attachment: att }
    end

    def multipart(subtype, parts)
      boundary = "=_inbox2_#{subtype}_#{@message.key}"
      { headers: ["Content-Type: multipart/#{subtype}; boundary=\"#{boundary}\""], boundary: boundary, parts: parts }
    end

    # Appends the node's body to `out`. Returns how many bytes were left out
    # (attachment payloads, when not fetching), so `size` can add them.
    def write(node, out, fetch:)
      if node[:parts]
        skipped = 0
        node[:parts].each do |part|
          out << "--#{node[:boundary]}\r\n" << part[:headers].join("\r\n") << "\r\n\r\n"
          skipped += write(part, out, fetch: fetch)
          out << "\r\n"
        end
        out << "--#{node[:boundary]}--\r\n"
        skipped
      elsif node[:attachment]
        att = node[:attachment]
        return base64_size(att.storage_key.present? ? att.size_bytes.to_i : 0) unless fetch

        out << base64(att.storage_key.present? ? S3StorageService.new.download(att.storage_key) : "")
        0
      else
        out << base64(node[:text].to_s.encode("UTF-8", invalid: :replace, undef: :replace))
        0
      end
    end

    def base64(data) = Base64.strict_encode64(data).scan(/.{1,#{LINE}}/o).join("\r\n")

    def base64_size(bytes)
      chars = 4 * ((bytes + 2) / 3)
      chars.zero? ? 0 : chars + 2 * ((chars - 1) / LINE)
    end
  end
end
