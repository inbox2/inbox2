module Disk
  # Server-side thumbnails for unsealed files: images (HEIC and TIFF included),
  # camera RAW, PDF and video, so imports, phone and API uploads and files from
  # before thumbnails existed all get one. The browser still makes one at
  # upload (lib/disk/thumbnail.js), which is the only path for sealed files;
  # this fills in what is missing.
  #
  # Untrusted bytes are decoded only by vips, pdftoppm and ffmpeg in their own
  # process with a time limit, never in the worker itself. vips runs with its
  # untrusted loaders blocked (ImageMagick, OpenEXR, FITS, MATLAB, OpenSlide,
  # SVG, PDF...), so a file named .jpg holding an EXR never reaches OpenEXR;
  # PDF goes through pdftoppm, BMP and video through ffmpeg held to the
  # demuxers and decoders on the lists below. .trivyignore relies on this.
  class Thumbnailer
    SIZE = 480 # px on the long edge, as THUMB_PX in the browser
    TIMEOUT_S = 60
    MAX_BYTES = { image: 100.megabytes, raw: 200.megabytes, pdf: 200.megabytes }.freeze # video streams instead
    RAW_EXTENSIONS = %w[cr2 cr3 nef nrw arw dng raf orf rw2 pef srw].freeze # as lib/disk/raw.js
    # Rack's MIME table misses some image formats browsers and cameras produce.
    IMAGE_EXTENSIONS = %w[jpg jpeg png gif webp avif heic heif bmp tif tiff].freeze
    VIDEO_EXTENSIONS = %w[mp4 m4v mov mkv webm avi].freeze

    Failed = Class.new(StandardError)

    def self.kind(name)
      ext = File.extname(name.to_s).delete_prefix(".").downcase
      return :raw if RAW_EXTENSIONS.include?(ext)
      return :image if IMAGE_EXTENSIONS.include?(ext)
      return :video if VIDEO_EXTENSIONS.include?(ext)

      :pdf if ext == "pdf"
    end

    def initialize(version, storage: Disk::Storage.current)
      @version = version
      @storage = storage
    end

    # Stores the thumbnail and records it. false when this version gets none.
    def run
      key = @version.variant_key(Disk::Version::VARIANT_THUMBNAIL)
      # The browser's landed first. Recorded here too: its PUT can succeed and the call
      # confirming it fail, and nothing else would ever notice the object.
      if @storage.size(key)
        @version.update_columns(thumbnail_storage_key: key) if @version.thumbnail_storage_key.blank?
        return true
      end
      return false if @version.sealed? || @version.size_bytes.zero?

      kind = self.class.kind(@version.node.name)
      return false unless kind
      return false if MAX_BYTES[kind] && @version.size_bytes > MAX_BYTES[kind]

      Dir.mktmpdir("disk-thumb") do |dir|
        out = File.join(dir, "thumb.webp")
        kind == :video ? video(dir, out) : still(kind, dir, out)
        raise Failed, "no thumbnail written" unless File.size?(out)

        @storage.put_file(key, out)
      end
      @version.update_columns(thumbnail_storage_key: key)
      true
    end

    # Embedded JPEG of a camera RAW: { offset, width, height, orientation } of the largest, or nil. Mirrors lib/disk/raw.js.
    def self.largest_jpeg(bytes)
      best = nil
      i = -1
      while (i = bytes.index("\xFF\xD8\xFF".b, i + 1))
        # Any APPn, a quantisation or a Huffman table; jpeg_info drops the sensor's lossless JPEG (SOF3).
        nxt = bytes.getbyte(i + 3)
        next unless nxt & 0xf0 == 0xe0 || nxt == 0xdb || nxt == 0xc4

        info = jpeg_info(bytes, i)
        best = info.merge(offset: i) if info && info[:width] * info[:height] > (best ? best[:width] * best[:height] : 0)
      end
      best
    end

    def self.jpeg_info(bytes, at)
      o = at + 2
      orientation = 1
      while o + 9 < bytes.bytesize && bytes.getbyte(o) == 0xff
        marker = bytes.getbyte(o + 1)
        len = bytes.byteslice(o + 2, 2).unpack1("n")
        orientation = tiff_orientation(bytes, o + 10) if marker == 0xe1 && bytes.byteslice(o + 4, 4) == "Exif"
        if marker.between?(0xc0, 0xc2)
          height, width = bytes.byteslice(o + 5, 4).unpack("nn")
          return { width: width, height: height, orientation: orientation }
        end
        return nil if marker == 0xda || len < 2

        o += 2 + len
      end
      nil
    end

    def self.tiff_orientation(bytes, at = 0)
      le = bytes.byteslice(at, 2) == "II"
      return 1 unless le || bytes.byteslice(at, 2) == "MM"

      u16, u32 = le ? %w[v V] : %w[n N]
      ifd = at + bytes.byteslice(at + 4, 4).to_s.unpack1(u32).to_i
      count = bytes.byteslice(ifd, 2).to_s.unpack1(u16).to_i
      count.times do |n|
        entry = ifd + 2 + n * 12
        break if entry + 12 > bytes.bytesize
        return bytes.byteslice(entry + 8, 2).unpack1(u16).nonzero? || 1 if bytes.byteslice(entry, 2).unpack1(u16) == 0x0112
      end
      1
    end

    ROTATIONS = { 3 => "d180", 6 => "d90", 8 => "d270" }.freeze
    VIPS_ENV = { "VIPS_BLOCK_UNTRUSTED" => "1" }.freeze
    VIDEO_DEMUXERS = "mov,mp4,m4a,3gp,3g2,mj2,matroska,webm,avi"
    VIDEO_DECODERS = "h264,hevc,vp8,vp9,av1,libdav1d,mpeg4,mjpeg,prores"

    private

    def still(kind, dir, out)
      src = File.join(dir, "source")
      File.open(src, "wb") { |f| @storage.read_into(@version.storage_key, f) }
      src = raw_preview(src, dir) if kind == :raw
      src = pdf_page(src, dir) if kind == :pdf
      src = bmp_frame(src, dir) if File.extname(@version.node.name).casecmp?(".bmp")
      thumbnail(src, out) # vips applies EXIF orientation itself
    end

    # The camera's own JPEG, turned upright when the RAW, not the JPEG, says how.
    def raw_preview(src, dir)
      bytes = File.binread(src)
      jpeg = self.class.largest_jpeg(bytes) || raise(Failed, "no embedded preview")
      path = File.join(dir, "preview.jpg")
      File.binwrite(path, bytes.byteslice(jpeg[:offset]..))
      rotation = ROTATIONS[self.class.tiff_orientation(bytes)] if jpeg[:orientation] == 1
      return path unless rotation

      upright = File.join(dir, "upright.jpg")
      sh(VIPS_ENV, "vips", "rot", path, upright, rotation)
      upright
    end

    # Page 1 at twice the thumbnail size, so vipsthumbnail still downsamples.
    def pdf_page(src, dir)
      prefix = File.join(dir, "page")
      sh("pdftoppm", "-q", "-png", "-f", "1", "-l", "1", "-singlefile", "-scale-to", (SIZE * 2).to_s, src, prefix)
      "#{prefix}.png"
    end

    # vips reads BMP only through ImageMagick, which stays blocked.
    def bmp_frame(src, dir)
      frame = File.join(dir, "frame.png")
      sh("ffmpeg", "-v", "error", "-nostdin", "-y", "-f", "bmp_pipe", "-codec_whitelist", "bmp", "-i", src, "-frames:v", "1", frame)
      frame
    end

    # A frame a second in (the first, for a shorter clip), read over a presigned
    # GET so a large video is never downloaded whole; vips makes the webp.
    def video(dir, out)
      url = @storage.preview_url(@version.storage_key)
      frame = File.join(dir, "frame.png")
      [["-ss", "1"], []].each do |seek|
        sh("ffmpeg", "-v", "error", "-nostdin", "-y", "-format_whitelist", VIDEO_DEMUXERS,
           "-codec_whitelist", VIDEO_DECODERS, *seek, "-i", url, "-frames:v", "1", frame)
        break if File.size?(frame)
      end
      thumbnail(frame, out)
    end

    def thumbnail(src, out) = sh(VIPS_ENV, "vipsthumbnail", src, "--size", "#{SIZE}x#{SIZE}", "-o", "#{out}[Q=80,strip]")

    # Runs a decoder, killed past TIMEOUT_S so a hostile or broken file cannot hold the worker.
    def sh(*cmd)
      env = cmd.first.is_a?(Hash) ? cmd.shift : {}
      Tempfile.create("disk-thumb-err") do |err|
        pid = Process.spawn(env, *cmd, in: File::NULL, out: File::NULL, err: err.path)
        status = begin
          Timeout.timeout(TIMEOUT_S) { Process.wait2(pid).last }
        rescue Timeout::Error
          Process.kill("KILL", pid)
          Process.wait(pid)
          raise Failed, "#{cmd.first}: timed out"
        end
        raise Failed, "#{cmd.first}: #{File.read(err.path).strip.truncate(300)}" unless status.success?
      end
    end
  end
end
