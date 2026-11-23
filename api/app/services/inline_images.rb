# data: image URIs in an HTML body → cid: references plus the parts to attach.
# Gmail and Outlook drop data: images from received mail, so a signature logo
# only shows when it travels as a multipart/related part (RFC 2392).
module InlineImages
  Part = Struct.new(:content_id, :content_type, :data, :filename)

  DATA_SRC = %r{src=(["'])data:(image/(?:png|jpe?g|gif|webp));base64,([A-Za-z0-9+/=\s]+)\1}i

  # Returns [html, parts]. The same image twice is attached once.
  def self.extract(html)
    return [html, []] if html.blank? || !html.include?("data:image/")

    parts = {}
    out = html.gsub(DATA_SRC) do
      quote, type, b64 = Regexp.last_match(1), Regexp.last_match(2).downcase, Regexp.last_match(3).gsub(/\s/, "")
      part = parts[b64] ||= begin
        n = parts.size + 1
        Part.new("img#{n}.#{SecureRandom.hex(6)}@inbox2", type, Base64.decode64(b64), "image#{n}.#{type.split('/').last.sub('jpeg', 'jpg')}")
      end
      "src=#{quote}cid:#{part.content_id}#{quote}"
    end
    [out, parts.values]
  end
end
