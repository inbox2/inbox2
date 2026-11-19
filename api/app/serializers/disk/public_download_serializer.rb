module Disk
  # URLs for one file reached through a public link. preview_url has no
  # attachment disposition so a viewer can fetch and render the bytes; url is
  # the attachment download and is null when the link hides downloads. Hiding
  # downloads is a deterrent: the preview bytes still reach the visitor.
  class PublicDownloadSerializer
    include Alba::Resource

    Download = Struct.new(:node, :url, :preview_url, :expires_at, keyword_init: true)

    attributes :url, :preview_url, :expires_at

    attribute :node do |d|
      Disk::PublicNodeSerializer.new(d.node).to_h
    end
  end
end
