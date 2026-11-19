module Disk
  # The meter (Disk::Quota): pool, used, reserved, and used split by kind.
  class QuotaSerializer
    include Alba::Resource

    attributes :pool_bytes, :used_bytes, :reserved_bytes, :available_bytes, :percent_used,
               :files_bytes, :versions_bytes, :trash_bytes, :types_bytes
  end
end
