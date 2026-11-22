module Sync
  # The list row, plus what a local mirror needs and the list UI doesn't:
  # the domain (per-domain tabs filter on it), the thread version, and for
  # address folders the member's folder key and whether the thread was given or
  # assigned to them (`direct`: in their Inbox whatever its folder).
  class ConversationSerializer < ::ConversationSerializer
    attribute(:domain_id) { |conv| conv.domain&.key }
    attribute(:change_seq) { |conv| conv.change_seq.to_i }
    attribute(:folder) { |conv| params[:folders]&.[](conv.id) }
    attribute(:direct) { |conv| params[:direct]&.include?(conv.id) || false }
  end
end
