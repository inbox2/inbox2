class ConversationAssignee < ApplicationRecord
  belongs_to :conversation
  belongs_to :membership

  validates :membership_id, uniqueness: { scope: :conversation_id }
end
