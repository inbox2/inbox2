# In-memory stand-in for Disk::Storage, so the suite runs without Garage.
# put_part plays the browser's PUT to a presigned part URL.
class FakeDiskStorage
  Part = Disk::Storage::Part

  attr_reader :objects, :multiparts, :deleted

  def initialize
    @objects = {}
    @multiparts = {}
    @deleted = []
  end

  def create_multipart(key)
    SecureRandom.hex(8).tap { |id| @multiparts[id] = { key: key, parts: {}, at: Time.current } }
  end

  def part_url(key, upload_id, number) = "https://storage.test/#{key}?partNumber=#{number}&uploadId=#{upload_id}"
  # size is a byte count, or the part's bytes themselves.
  def put_part(upload_id, number, size) = @multiparts.fetch(upload_id)[:parts][number] = size

  def parts(_key, upload_id)
    mp = @multiparts[upload_id] || raise(Aws::S3::Errors::NoSuchUpload.new(nil, "no such upload"))
    mp[:parts].sort.map { |n, size| Part.new(number: n, size: size.is_a?(String) ? size.bytesize : size, etag: "\"etag#{n}\"") }
  end

  def complete_multipart(key, upload_id, parts)
    mp = @multiparts.delete(upload_id) || raise(Aws::S3::Errors::NoSuchUpload.new(nil, "no such upload"))
    bodies = mp[:parts].sort.map(&:last)
    bodies.all?(String) ? put_bytes(key, bodies.join) : put(key, parts.sum(&:size))
  end

  def abort_multipart(_key, upload_id) = @multiparts.delete(upload_id)
  def put_empty(key) = put(key, 0)
  def put(key, size, at: Time.current) = @objects[key] = { size: size, at: at }
  def put_bytes(key, bytes)
    bytes = bytes.read if bytes.respond_to?(:read)
    @objects[key] = { size: bytes.bytesize, at: Time.current, body: bytes.b }
  end

  def put_file(key, path) = put_bytes(key, File.binread(path))
  def read_into(key, io) = io.write(read_range(key, 0, size(key)))
  def read_from(key, offset) = read_range(key, offset, size(key)).scan(/.{1,7}/mn).each { |c| yield c } # small chunks, split mid-line

  # Objects stored without a body read as "a" repeated.
  def read_range(key, offset, length)
    o = @objects.fetch(key)
    (o[:body] || ("a" * o[:size]).b).byteslice(offset, length) || "".b
  end
  def size(key) = @objects.dig(key, :size)
  def get_url(key, filename: nil) = "https://storage.test/#{key}?attachment=#{filename}"
  def preview_url(key) = "https://storage.test/#{key}?inline"
  def put_url(key) = "https://storage.test/#{key}?put"
  def origins = ["https://storage.test"]
  def copy(source_key, target_key, size)
    body = @objects.dig(source_key, :body)
    body ? put_bytes(target_key, body) : put(target_key, size)
  end

  def delete(keys)
    keys.compact.each do |k|
      @deleted << k
      @objects.delete(k)
    end
  end

  def each_object(&) = @objects.each { |k, o| yield k, o[:size], o[:at] }
  def open_multiparts = @multiparts.map { |id, mp| [mp[:key], id, mp[:at]] }
end

RSpec.shared_context "fake disk storage" do
  let(:storage) { FakeDiskStorage.new }

  before { allow(Disk::Storage).to receive(:current).and_return(storage) }
end
