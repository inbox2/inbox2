class ConversationTag < ApplicationRecord
  belongs_to :conversation
  belongs_to :tag

  validates :tag_id, uniqueness: { scope: :conversation_id }
end
