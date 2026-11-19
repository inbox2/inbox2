require "open3"

# Extracts searchable text from attachment content (spec 6.3.5)
# Supports text-based formats directly; binary formats require external tools.
class AttachmentTextExtractor
  MAX_TEXT_LENGTH = 100_000
  # ponytail: a page cap bounds the work instead of a wall-clock timeout; add one
  # (popen + kill) if a hostile PDF ever pins a worker.
  PDF_MAX_PAGES = 50

  # Text layer of a PDF via poppler's pdftotext (in the api image). nil when the
  # PDF has no text layer (a scan) or pdftotext fails — search just won't see it.
  # ponytail: no OCR; scanned PDFs stay unsearchable until someone needs them.
  def self.pdf_text(bytes)
    out, status = Open3.capture2("pdftotext", "-q", "-l", PDF_MAX_PAGES.to_s, "-enc", "UTF-8", "-", "-",
                                 stdin_data: bytes, binmode: true)
    return nil unless status.success?

    text = out.force_encoding("UTF-8").scrub("").gsub(/\s+/, " ").strip
    text.presence&.truncate(MAX_TEXT_LENGTH)
  rescue Errno::ENOENT
    nil
  end

  def initialize(attachment)
    @attachment = attachment
  end

  def extract(content)
    return nil unless @attachment.searchable?
    return nil if content.blank?

    text = case @attachment.content_type
    when "text/html"
      strip_html(content)
    when "text/plain", "text/csv", "text/markdown", "application/json"
      content.to_s
    else
      content.to_s if @attachment.send(:filename_text_extension?)
    end

    text&.truncate(MAX_TEXT_LENGTH)
  end

  private

  def strip_html(html)
    html.to_s
      .gsub(/<script[^>]*>.*?<\/script>/mi, "")
      .gsub(/<style[^>]*>.*?<\/style>/mi, "")
      .gsub(/<[^>]+>/, " ")
      .gsub(/&\w+;/, " ")
      .gsub(/\s+/, " ")
      .strip
  end
end
