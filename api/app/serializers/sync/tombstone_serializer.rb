module Sync
  class TombstoneSerializer
    include Alba::Resource

    attribute(:type) { |t| t.record_type }
    attribute(:id) { |t| t.record_key }
  end
end
