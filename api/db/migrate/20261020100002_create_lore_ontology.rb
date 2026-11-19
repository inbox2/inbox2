# Lore ontology (docs/Ontology.md, docs/plans/lore.md §4): the organizations,
# people, products and projects mined from a domain's mail, the facts about
# them (each with its verbatim quote) and which threads mention them. Domain
# scoped: team knowledge, never shared across an org's distinct companies.
class CreateLoreOntology < ActiveRecord::Migration[8.1]
  def change
    create_table :lore_entities, if_not_exists: true do |t|
      t.string :key, null: false
      t.bigint :organization_id, null: false
      t.bigint :domain_id, null: false
      t.string :kind, null: false
      t.string :name, null: false
      t.string :normalized_name, null: false
      t.string :email_domain
      t.string :address
      t.datetime :first_seen_at
      t.datetime :last_seen_at
      t.integer :mention_count, default: 0, null: false
      t.timestamps
    end
    add_index :lore_entities, :key, unique: true, if_not_exists: true
    add_index :lore_entities, %i[domain_id kind normalized_name], unique: true, name: "idx_lore_entities_identity", if_not_exists: true
    add_index :lore_entities, %i[organization_id mention_count], if_not_exists: true
    add_foreign_key :lore_entities, :organizations, on_delete: :cascade unless foreign_key_exists?(:lore_entities, :organizations)
    add_foreign_key :lore_entities, :domains, on_delete: :cascade unless foreign_key_exists?(:lore_entities, :domains)

    create_table :lore_facts, if_not_exists: true do |t|
      t.bigint :lore_entity_id, null: false
      t.string :kind, null: false
      t.string :name, null: false
      t.text :value
      t.bigint :related_entity_id
      t.text :quote
      t.bigint :conversation_id
      t.bigint :message_id
      t.float :confidence, default: 1.0, null: false
      t.float :grounding, default: 1.0, null: false
      t.integer :support, default: 1, null: false
      t.string :fingerprint, null: false
      t.datetime :created_at, null: false
    end
    add_index :lore_facts, %i[lore_entity_id fingerprint], unique: true, if_not_exists: true
    add_index :lore_facts, :related_entity_id, if_not_exists: true
    add_index :lore_facts, :conversation_id, if_not_exists: true
    add_foreign_key :lore_facts, :lore_entities, on_delete: :cascade unless foreign_key_exists?(:lore_facts, column: :lore_entity_id)
    add_foreign_key :lore_facts, :lore_entities, column: :related_entity_id, on_delete: :cascade unless foreign_key_exists?(:lore_facts, column: :related_entity_id)
    add_foreign_key :lore_facts, :conversations, on_delete: :cascade unless foreign_key_exists?(:lore_facts, :conversations)
    add_foreign_key :lore_facts, :messages, on_delete: :nullify unless foreign_key_exists?(:lore_facts, :messages)

    create_table :lore_mentions, if_not_exists: true do |t|
      t.bigint :lore_entity_id, null: false
      t.bigint :conversation_id, null: false
      t.datetime :created_at, null: false
    end
    add_index :lore_mentions, %i[lore_entity_id conversation_id], unique: true, if_not_exists: true
    add_index :lore_mentions, :conversation_id, if_not_exists: true
    add_foreign_key :lore_mentions, :lore_entities, on_delete: :cascade unless foreign_key_exists?(:lore_mentions, :lore_entities)
    add_foreign_key :lore_mentions, :conversations, on_delete: :cascade unless foreign_key_exists?(:lore_mentions, :conversations)
  end
end
