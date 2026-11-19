# A mined fact about an entity: an attribute ("role" = "procurement manager")
# or a relation to another entity (works_at, client_of, uses, about). Mined
# facts carry the verbatim quote that grounds them; header-derived ones don't.
# Identical facts collapse on (entity, fingerprint) and gain support instead.
class LoreFact < ApplicationRecord
  KIND_ATTRIBUTE = "attribute".freeze
  KIND_RELATION = "relation".freeze
  KINDS = [KIND_ATTRIBUTE, KIND_RELATION].freeze

  RELATION_WORKS_AT = "works_at".freeze
  RELATION_CLIENT_OF = "client_of".freeze
  RELATION_USES = "uses".freeze
  RELATION_ABOUT = "about".freeze
  RELATIONS = [RELATION_WORKS_AT, RELATION_CLIENT_OF, RELATION_USES, RELATION_ABOUT].freeze

  belongs_to :entity, class_name: "LoreEntity", foreign_key: :lore_entity_id
  belongs_to :related_entity, class_name: "LoreEntity", optional: true
  belongs_to :conversation, optional: true
  belongs_to :message, optional: true

  validates :kind, inclusion: { in: KINDS }

  # Removed by hand. The row stays so the miner finds it and writes nothing (docs/Ontology.md).
  scope :live, -> { where(removed_at: nil) }

  def self.fingerprint(kind, name, value, related_entity_id)
    Digest::SHA1.hexdigest([kind, name, value.to_s.downcase.squish, related_entity_id].join("\u0000"))
  end
end
