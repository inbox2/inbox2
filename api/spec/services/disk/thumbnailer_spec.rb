require "rails_helper"

# Server-side thumbnails for unsealed files (spec F5, the browser's thumbnail stays for sealed ones).
RSpec.describe Disk::Thumbnailer do
  include_context "disk org"

  let(:root) { make_share("Photos").root_node }
  let(:vips) { system("command -v vipsthumbnail >/dev/null") }

  def stored(name, bytes)
    node = make_stored_file(root, name, size: bytes.bytesize, mime: "application/octet-stream")
    storage.put_bytes(node.current_version.storage_key, bytes)
    node.current_version
  end

  def tiff(orientation) = ["II", 42, 8, 1, 0x0112, 3, 1, orientation, 0].pack("a2vVvvvVvv")

  def jpeg(width, height)
    Dir.mktmpdir do |dir|
      system("vips", "black", "#{dir}/a.jpg", width.to_s, height.to_s, exception: true)
      File.binread("#{dir}/a.jpg")
    end
  end

  def thumb_size(version)
    Dir.mktmpdir do |dir|
      File.binwrite("#{dir}/t.webp", storage.read_range(version.thumbnail_storage_key, 0, 10.megabytes))
      `vipsheader -f width #{dir}/t.webp`.to_i.then { |w| [w, `vipsheader -f height #{dir}/t.webp`.to_i] }
    end
  end

  it "knows which files it can draw" do
    expect(%w[a.JPG b.heic c.CR3 d.mov e.pdf f.docx].map { described_class.kind(_1) })
      .to eq([:image, :image, :raw, :video, :pdf, nil])
  end

  it "finds a RAW's largest embedded JPEG and both orientations" do
    small = "\xFF\xD8\xFF\xDB\x00\x02\xFF\xC0\x00\x0B\x08\x00\x78\x00\xA0\x01\x01\x11\x00".b
    big = "\xFF\xD8\xFF\xDB\x00\x02\xFF\xC0\x00\x0B\x08\x0F\xA0\x17\x70\x01\x01\x11\x00".b
    lossless = "\xFF\xD8\xFF\xC4\x00\x04\x00\x00\xFF\xC3\x00\x0B\x08\x40\x00\x60\x00\x01\x01\x11\x00".b
    bytes = tiff(6) + "xyz".b + small + big + lossless
    expect(described_class.largest_jpeg(bytes)).to include(offset: bytes.index(big), width: 6000, height: 4000, orientation: 1)
    expect(described_class.tiff_orientation(bytes)).to eq(6)
    expect(described_class.largest_jpeg("\xFF\xD8\xFF\xC4abc".b)).to be_nil
  end

  it "skips sealed versions and files it cannot draw" do
    expect(described_class.new(stored("notes.docx", "x")).run).to be(false)
    sealed = stored("b.jpg", "x").tap { _1.update_columns(wrapped_key: "k") }
    expect(described_class.new(sealed).run).to be(false)
  end

  it "records a browser's thumbnail that landed but was never confirmed, without redrawing it" do
    done = stored("a.jpg", "x")
    key = done.variant_key(Disk::Version::VARIANT_THUMBNAIL)
    storage.put(key, 10)
    expect(described_class.new(done).run).to be(true)
    expect(done.reload.thumbnail_storage_key).to eq(key)
    expect(storage.size(key)).to eq(10)
  end

  it "queues a thumbnail for each new unsealed version" do
    expect { make_stored_file(root, "c.png", size: 3) }.to have_enqueued_job(Disk::ThumbnailJob)
  end

  context "with vips installed" do
    before { skip "vips is not installed" unless vips }

    it "thumbnails an image to 480px on its long edge" do
      v = stored("photo.jpg", jpeg(1200, 800))
      expect(described_class.new(v).run).to be(true)
      expect(v.reload.thumbnail_storage_key).to eq(v.variant_key("thumbnail"))
      expect(thumb_size(v)).to eq([480, 320])
    end

    it "turns a RAW's embedded preview upright by the RAW's orientation" do
      v = stored("shot.NEF", tiff(6) + "sensor".b + jpeg(1200, 800))
      expect(described_class.new(v).run).to be(true)
      expect(thumb_size(v)).to eq([320, 480])
    end

    it "never hands vips's untrusted loaders a file, whatever its name says" do
      bytes = Dir.mktmpdir do |dir|
        system("vips", "black", "#{dir}/a.v", "40", "40", exception: true) # vipsload is an untrusted loader
        File.binread("#{dir}/a.v")
      end
      expect { described_class.new(stored("photo.jpg", bytes)).run }.to raise_error(described_class::Failed)
    end

    it "draws page 1 of a PDF through pdftoppm" do
      skip "pdftoppm is not installed" unless system("command -v pdftoppm >/dev/null")
      pdf = "%PDF-1.1\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj " \
            "3 0 obj<</Type/Page/MediaBox[0 0 400 200]/Parent 2 0 R>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n"
      v = stored("doc.pdf", pdf)
      expect(described_class.new(v).run).to be(true)
      expect(thumb_size(v).first).to eq(480) # pdftoppm rounds the height
    end

    it "draws a BMP through ffmpeg" do
      skip "ffmpeg is not installed" unless system("command -v ffmpeg >/dev/null")
      bmp = Dir.mktmpdir do |dir|
        system("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=size=960x480", "-frames:v", "1", "#{dir}/a.bmp", exception: true)
        File.binread("#{dir}/a.bmp")
      end
      v = stored("scan.BMP", bmp)
      expect(described_class.new(v).run).to be(true)
      expect(thumb_size(v)).to eq([480, 240])
    end
  end
end
