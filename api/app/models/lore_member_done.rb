# One member's tick on a Lore item in a personal bucket (TriageLabel::PERSONAL) of a
# shared MX domain: hides the thread from that member's Lore, nobody else's. Work
# items don't come here; ticking those archives the thread for the team.
class LoreMemberDone < ApplicationRecord
  # The conversations/bulk verbs; clients' write-back queues replay them like any other action.
  ACTION_DONE = "lore_done".freeze
  ACTION_UNDONE = "lore_undone".freeze

  belongs_to :conversation
  belongs_to :membership

  def self.mark!(conversations, membership)
    now = Time.current
    rows = conversations.map { |c| { conversation_id: c.id, membership_id: membership.id, created_at: now, updated_at: now } }
    insert_all(rows, unique_by: %i[conversation_id membership_id]) if rows.any?
  end
end
