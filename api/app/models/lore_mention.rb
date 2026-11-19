# A thread that mentions an entity (the `about` edge, one row per pair).
class LoreMention < ApplicationRecord
  belongs_to :entity, class_name: "LoreEntity", foreign_key: :lore_entity_id
  belongs_to :conversation
end
