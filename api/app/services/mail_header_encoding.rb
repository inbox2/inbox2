# RFC 5322 header encoding helpers for hand-composed MIME (OutboundMailPublisher).
#
# Headers are ASCII-only: raw UTF-8 bytes get re-interpreted by receiving MTAs
# ("Ömer" arrives as "ÃƒÂ–mer"), so non-ASCII text must be RFC 2047 B-encoded.
# Mirrors the Rust helpers in ui/desktop/core/src/sync/interactive.rs.
module MailHeaderEncoding
  module_function

  # Raw bytes per encoded-word. RFC 2047 §2 caps an encoded-word at 75 chars:
  # base64(45 bytes) = 60 chars, + "=?UTF-8?B?" (10) + "?=" (2) = 72. A 100-char
  # Chinese or Arabic subject B-encodes to ~400 chars, so without chunking the
  # header blows past both the 75-char encoded-word cap and the RFC 5322
  # 998-octet line limit, and strict receivers refuse to decode it.
  MAX_ENCODED_WORD_BYTES = 45

  # RFC 2047 B-encode header text when it contains non-ASCII, folded into
  # multiple encoded-words when long. Text is NFC-normalized first so a
  # macOS-composed "أ" (NFD: alef + hamza) goes out as the single precomposed
  # codepoint every other client sends.
  def encode_text(str)
    return str if str.nil?
    str = str.unicode_normalize(:nfc)
    return str if str.ascii_only?
    chunk_utf8(str, MAX_ENCODED_WORD_BYTES)
      .map { |chunk| "=?UTF-8?B?#{Base64.strict_encode64(chunk)}?=" }
      .join("\r\n ") # RFC 2047 §5: adjacent encoded-words fold on CRLF + WSP
  end

  # Split into pieces of at most `max` UTF-8 bytes without cutting a character.
  # Each encoded-word must decode standalone, so a multi-byte character may
  # never straddle two of them. No character exceeds 4 bytes, so every chunk
  # fits as long as max >= 4.
  def chunk_utf8(str, max)
    chunks = []
    current = +""
    str.each_char do |ch|
      if current.bytesize + ch.bytesize > max
        chunks << current
        current = +""
      end
      current << ch
    end
    chunks << current unless current.empty?
    chunks
  end

  # Encode a MIME parameter value (`filename`, `name`). RFC 2047 encoded-words
  # are NOT legal inside a parameter value — the mechanism is RFC 2231's
  # extended syntax — so an Arabic or Chinese filename sent as
  # `filename="=?UTF-8?B?...?="` shows up literally in strict clients.
  # ponytail: no RFC 2231 continuations (filename*0*=), so a >~70-char non-ASCII
  # filename yields one long parameter line. Add them if a receiver complains.
  def encode_param(name, value)
    value = value.to_s.unicode_normalize(:nfc)
    return "#{name}=\"#{value.gsub('"', '')}\"" if value.ascii_only?
    "#{name}*=UTF-8''#{percent_encode(value)}"
  end

  # RFC 2231 percent-encoding: everything outside the unreserved set, byte-wise
  # over the UTF-8 encoding. Over-encoding is always safe to decode.
  def percent_encode(str)
    str.b.gsub(/[^A-Za-z0-9\-_.~]/) { |b| format("%%%02X", b.ord) }
  end

  # Split an address-list header on top-level commas (quoted display names may
  # contain commas: `"Eryigit, Ömer" <o@x>, b@y`).
  def split_addresses(list)
    return [] if list.blank?
    parts = []
    current = +""
    in_quotes = false
    list.each_char do |c|
      case c
      when '"'
        in_quotes = !in_quotes
        current << c
      when ","
        if in_quotes
          current << c
        else
          parts << current
          current = +""
        end
      else
        current << c
      end
    end
    parts << current
    parts.map(&:strip).reject(&:empty?)
  end

  # Encode the display-name part of each mailbox in an address-list header
  # (`Name <a@b>` / `"Name" <a@b>` / bare `a@b`) per RFC 2047.
  def encode_address_header(list)
    split_addresses(list).map do |mailbox|
      next mailbox if mailbox.ascii_only?

      lt = mailbox.rindex("<")
      if lt
        name = mailbox[0...lt].strip.delete_prefix('"').delete_suffix('"').strip
        "#{encode_text(name)} #{mailbox[lt..].strip}"
      else
        mailbox
      end
    end.join(", ")
  end

  # Bare addr-specs from an address-list header — what SMTP envelopes (MAIL
  # FROM / RCPT TO) want: `Name <a@b>, c@d` → ["a@b", "c@d"].
  def bare_addresses(list)
    split_addresses(list).map do |mailbox|
      angle = mailbox[/<([^>]+)>\s*\z/, 1]
      (angle || mailbox).strip
    end.reject(&:empty?)
  end
end
