module Disk
  # Where a member's access comes from (Disk::Access::Source).
  class AccessSourceSerializer
    include Alba::Resource

    attributes :kind, :role

    attribute :node_id do |s|
      s.node&.key
    end

    attribute :share_id do |s|
      s.share&.key
    end
  end
end
