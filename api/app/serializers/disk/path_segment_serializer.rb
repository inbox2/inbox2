module Disk
  # A breadcrumb segment, from the drive or share root down, cut to what the
  # caller can see. A share's top folder is named for the share and carries
  # its slug; C:\ has no name.
  class PathSegmentSerializer
    include Alba::Resource

    attribute :id, &:key

    attribute :name do |n|
      if n.sealed? then nil
      elsif n.root? then n.share&.name
      else n.name
      end
    end

    attributes :sealed, :short_id, :kind

    attribute :share_slug do |n|
      n.root? ? n.share&.slug : nil
    end
  end
end
