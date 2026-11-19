# Shared helpers for accepting and serving user-uploaded image assets (avatars,
# org icons/logos) safely. The threat is stored XSS: a client can set any
# multipart Content-Type, so trusting it lets an attacker upload an SVG (which
# can carry <script>) and have it served inline on our origin.
#
# Defence: on upload we ignore the client's Content-Type and sniff the real
# bytes, accepting only true raster images; on serve we force a safe type,
# disable content sniffing, and never serve a non-allowlisted type inline.
module ImageAssets
  extend ActiveSupport::Concern

  # Accepted on UPLOAD — verified by magic bytes, not the client header.
  UPLOAD_IMAGE_TYPES = %w[image/png image/jpeg image/gif image/webp].freeze
  # Safe to serve INLINE (binary formats that browsers won't execute). SVG is
  # deliberately excluded — it renders as an active document.
  INLINE_IMAGE_TYPES = (UPLOAD_IMAGE_TYPES + %w[image/x-icon image/vnd.microsoft.icon]).freeze
  MAX_IMAGE_BYTES = 2.megabytes

  private

  # Validate an uploaded file and return its detected (trusted) content-type, or
  # render an error and return nil. Callers must `return unless` on the result.
  def validate_image_upload!(file, label:)
    if file.blank?
      render json: ErrorSerializer.serialize("No file provided", status: 422), status: :unprocessable_content
      return nil
    end

    if file.size > MAX_IMAGE_BYTES
      render json: ErrorSerializer.serialize("#{label} must be under 2MB", status: 422), status: :unprocessable_content
      return nil
    end

    detected = detect_image_type(file)
    unless detected
      render json: ErrorSerializer.serialize("#{label} must be a PNG, JPEG, GIF, or WebP image", status: 422), status: :unprocessable_content
      return nil
    end

    detected
  end

  # Sniff the real image type from the leading bytes. Returns a content-type
  # string for known raster formats, else nil. SVG/HTML/scripts have no matching
  # signature and are rejected.
  def detect_image_type(file)
    head = file.read(16)
    file.rewind
    return nil if head.nil?

    head = head.b
    return "image/png"  if head.start_with?("\x89PNG\r\n\x1a\n".b)
    return "image/jpeg" if head[0, 3] == "\xFF\xD8\xFF".b
    return "image/gif"  if head.start_with?("GIF87a".b) || head.start_with?("GIF89a".b)
    return "image/webp" if head[0, 4] == "RIFF".b && head[8, 4] == "WEBP".b

    nil
  end

  # Stream image bytes with content sniffing disabled. Allowlisted binary image
  # types are served inline; anything else is forced to a download so a
  # poisoned/legacy object (e.g. a stored SVG) can never execute on our origin.
  def send_image_asset(bytes, content_type)
    response.headers["X-Content-Type-Options"] = "nosniff"

    if INLINE_IMAGE_TYPES.include?(content_type)
      send_data bytes, type: content_type, disposition: "inline"
    else
      send_data bytes, type: "application/octet-stream", disposition: "attachment"
    end
  end
end
