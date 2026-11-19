module Disk
  # A part storage already holds (Disk::Storage::Part), for resuming.
  class StoredPartSerializer
    include Alba::Resource

    attributes :number, :etag

    attribute :size_bytes, &:size
  end
end
