# frozen_string_literal: true

# Render a plain-text mail body as the HTML alternative part.
#
# Mobile composers (iOS/Android) post `body_plain` only, so without this the
# outbound MIME is a text/plain singlepart — a reply typed on the phone reaches
# the recipient as text-only mail with a `> `-prefixed quote no client collapses.
# Mirrors the Rust core's `sync::util::plain_to_html` (local channels) so both
# send paths produce the same shape.
class PlainBodyHtml
  WRAPPER_STYLE = "font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;font-size:14px;color:#111"
  QUOTE_STYLE = "margin:0 0 0 4px;padding-left:10px;border-left:2px solid #ccc;color:#555"
  URL = %r{\Ahttps?://\S+\z}

  class << self
    # Returns nil for blank input so callers can `||` it against a real HTML body.
    def call(text)
      return nil if text.blank?

      lines = text.to_s.gsub("\r\n", "\n").split("\n", -1)
      # Group consecutive quoted lines so the quoted original becomes one
      # blockquote (which Gmail/Outlook collapse) rather than inline text.
      html = lines.chunk_while { |a, b| quoted?(a) == quoted?(b) }.map do |run|
        if quoted?(run.first)
          "<blockquote type=\"cite\" style=\"#{QUOTE_STYLE}\">#{render(run.map { |l| unquote(l) })}</blockquote>"
        else
          render(run)
        end
      end.join

      "<div style=\"#{WRAPPER_STYLE}\">#{html}</div>"
    end

    private

    def quoted?(line) = line.start_with?(">")

    # Strip one level of `> ` quoting; nested levels stay as text in the block.
    def unquote(line) = line.start_with?("> ") ? line.delete_prefix("> ") : line.delete_prefix(">")

    def render(lines) = lines.map { |l| linkify(CGI.escapeHTML(l)) }.join("<br>")

    # Plain-text clients autolink bare URLs; HTML ones mostly don't, so a pasted
    # link would go dead without this.
    def linkify(escaped)
      escaped.split(" ").map do |tok|
        next tok unless tok.match?(URL)

        url = tok.sub(/[.,);:!?]+\z/, "")
        "<a href=\"#{url}\">#{url}</a>#{tok[url.length..]}"
      end.join(" ")
    end
  end
end
