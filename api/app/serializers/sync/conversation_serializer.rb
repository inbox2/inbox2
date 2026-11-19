module Sync
  # The list row, plus what a local mirror needs and the list UI doesn't:
  # the domain (per-domain tabs filter on it) and the thread version.
  class ConversationSerializer < ::ConversationSerializer
    attribute(:domain_id) { |conv| conv.domain&.key }
    attribute(:change_seq) { |conv| conv.change_seq.to_i }
  end
end
