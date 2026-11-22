module Disk
  # An item's link in the inbox2 web app, as the viewer reaches it (Disk::WebPath).
  # Finder's "Copy inbox2 link" asks for it (docs/Disk-Sync.md).
  class WebLinkSerializer
    include Alba::Resource

    Link = Struct.new(:url, keyword_init: true)

    attributes :url
  end
end
