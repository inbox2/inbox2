# A fact on an entity page; `related` names the other end of a relation.
class LoreFactSerializer
  include Alba::Resource

  # The stable mined identity: the opaque id this API edits a fact by.
  attribute(:id) { |f| f.fingerprint }
  attributes :kind, :name, :value, :quote, :confidence

  attribute :related do |f|
    f.related_entity && { id: f.related_entity.key, kind: f.related_entity.kind, name: f.related_entity.name }
  end

  attribute :conversation_id do |f|
    f.conversation&.key
  end
end
