class Note < ApplicationRecord
  key_prefix "note"

  belongs_to :conversation
  belongs_to :organization
  belongs_to :membership
  belongs_to :parent_note, class_name: "Note", optional: true

  has_many :replies, class_name: "Note", foreign_key: :parent_note_id, dependent: :destroy
  has_many :reactions, class_name: "NoteReaction", dependent: :destroy

  validates :body, presence: true
end
