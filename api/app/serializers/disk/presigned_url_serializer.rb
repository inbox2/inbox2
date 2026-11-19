module Disk
  # A short-lived URL straight to storage. For a part upload, number says which part.
  class PresignedUrlSerializer
    include Alba::Resource

    Url = Struct.new(:url, :expires_at, :number, keyword_init: true)

    attributes :number, :url, :expires_at
  end
end
