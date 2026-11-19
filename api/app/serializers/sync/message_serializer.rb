module Sync
  class MessageSerializer < ::MessageSerializer
    attribute(:change_seq) { |msg| msg.change_seq.to_i }
  end
end
