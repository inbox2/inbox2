module Disk
  # A presigned GET for one version's bytes (or its thumbnail or rendition).
  # It honours Range and always downloads as an attachment.
  class DownloadSerializer
    include Alba::Resource

    Download = Struct.new(:url, :expires_at, :version, :variant, keyword_init: true)

    attributes :url, :expires_at, :variant

    attribute :version_id do |d|
      d.version.key
    end

    attribute :size_bytes do |d|
      d.variant ? nil : d.version.size_bytes
    end
  end
end
