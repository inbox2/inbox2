# Hand edits to the Lore ontology (docs/Ontology.md "Editing", TODO 48.15): removals and
# merges are flags on the row the miner would find, so it does not bring them back.
class AddLoreEditingColumns < ActiveRecord::Migration[8.1]
  def change
    add_column :lore_entities, :removed_at, :datetime, if_not_exists: true
    add_column :lore_entities, :merged_into_id, :bigint, if_not_exists: true
    add_column :lore_entities, :name_locked, :boolean, default: false, null: false, if_not_exists: true
    add_column :lore_facts, :removed_at, :datetime, if_not_exists: true
    add_foreign_key :lore_entities, :lore_entities, column: :merged_into_id, on_delete: :nullify, if_not_exists: true
  end
end
