module Sync
  class NoteSerializer < ::NoteSerializer
    attribute(:conversation_id) { |note| note.conversation.key }
    attribute(:change_seq) { |note| note.change_seq.to_i }
  end
end
