# One thing a domain's mail talks about (docs/Ontology.md): an organization,
# person, product/tool or project. Identity is (domain, kind, normalized_name);
# people seen as senders use their address as the normalized name.
class LoreEntity < ApplicationRecord
  key_prefix "ent"

  KIND_ORGANIZATION = "organization".freeze
  KIND_PERSON = "person".freeze
  KIND_PRODUCT = "product".freeze
  KIND_PROJECT = "project".freeze
  KINDS = [KIND_ORGANIZATION, KIND_PERSON, KIND_PRODUCT, KIND_PROJECT].freeze

  # A hand edit the miner must not undo, or a member's request we can't honour.
  class EditRefused < StandardError; end

  scope :live, -> { where(removed_at: nil, merged_into_id: nil) }

  belongs_to :organization
  belongs_to :domain
  belongs_to :merged_into, class_name: "LoreEntity", optional: true
  has_many :facts, class_name: "LoreFact", dependent: :destroy
  has_many :mentions, class_name: "LoreMention", dependent: :destroy

  validates :kind, inclusion: { in: KINDS }
  validates :name, :normalized_name, presence: true

  # Editing (docs/Ontology.md). A rename keeps the identity, so the miner still finds the row.
  def rename!(new_name)
    update!(name: new_name.to_s.strip.first(LoreFindings::MAX_NAME), name_locked: true)
  end

  # The miner would re-create the old kind from headers, so a stub keeps the old
  # identity and points here; the row itself keeps its key.
  def change_kind!(new_kind)
    raise EditRefused, "Unknown type." unless KINDS.include?(new_kind)
    return if new_kind == kind
    raise EditRefused, "There is already one with that name and type. Merge them instead." if
      self.class.exists?(domain_id: domain_id, kind: new_kind, normalized_name: normalized_name)

    transaction do
      old = kind
      update!(kind: new_kind)
      self.class.create!(organization_id: organization_id, domain_id: domain_id, kind: old, name: name,
                         normalized_name: normalized_name, merged_into: self, name_locked: true)
    end
  end

  # The row stays, flagged: the miner finds it and writes nothing.
  def remove!
    now = Time.current
    transaction do
      update!(removed_at: now)
      LoreFact.where("lore_entity_id = :id OR related_entity_id = :id", id: id).update_all(removed_at: now)
    end
  end

  # Fold this entity into `target`, leaving a pointer so the miner lands on the target.
  def merge_into!(target)
    raise EditRefused, "Pick a different one to merge with." if target == self
    raise EditRefused, "Those two belong to different domains." unless target.domain_id == domain_id

    transaction do
      facts.find_each do |f|
        target.facts.exists?(fingerprint: f.fingerprint) ? f.destroy! : f.update_columns(lore_entity_id: target.id)
      end
      # Relations pointing here: their fingerprint names the far end, so it moves too.
      LoreFact.where(related_entity_id: id).find_each do |f|
        fp = LoreFact.fingerprint(f.kind, f.name, f.value, target.id)
        if f.lore_entity_id == target.id || LoreFact.exists?(lore_entity_id: f.lore_entity_id, fingerprint: fp)
          f.destroy!
        else
          f.update_columns(related_entity_id: target.id, fingerprint: fp)
        end
      end
      LoreFact.where(lore_entity_id: target.id, related_entity_id: target.id).delete_all
      LoreMention.where(lore_entity_id: id).where.not(conversation_id: target.mentions.select(:conversation_id))
        .update_all(lore_entity_id: target.id)
      LoreMention.where(lore_entity_id: id).delete_all
      target.update_columns(mention_count: target.mentions.count,
                            first_seen_at: [target.first_seen_at, first_seen_at].compact.min,
                            last_seen_at: [target.last_seen_at, last_seen_at].compact.max)
      self.class.where(merged_into_id: id).update_all(merged_into_id: target.id)
      update_columns(merged_into_id: target.id, mention_count: 0)
    end
  end
end
