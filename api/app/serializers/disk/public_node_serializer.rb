module Disk
  # A node as an anonymous link visitor sees it: no drive, share, people or path above the link.
  class PublicNodeSerializer < ::ApplicationSerializer
    attributes :kind, :name, :mime, :size_bytes, :content_modified_at
  end
end
