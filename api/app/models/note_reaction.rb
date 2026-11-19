class NoteReaction < ApplicationRecord
  belongs_to :note
  belongs_to :membership

  validates :emoji, presence: true, length: { maximum: 20 }
  validates :membership_id, uniqueness: { scope: [:note_id, :emoji], message: "already reacted with this emoji" }
end
