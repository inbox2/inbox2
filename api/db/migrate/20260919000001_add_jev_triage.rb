# Jev triage (docs/Triage.md): an action label + a priority score on every MX
# thread, an org-editable label catalogue, and a `not_for` hint on spaces that
# Jev reads alongside the description.
#
# Its own file so production actually migrates (prod already recorded
# 20260522000001). Everything is ALSO in the initial schema for fresh installs;
# `if_not_exists` makes this a no-op there.
class AddJevTriage < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :triage_label, :string, if_not_exists: true
    add_column :conversations, :triage_priority, :float, if_not_exists: true
    add_column :conversations, :triage_source, :string, if_not_exists: true
    add_column :spaces, :not_for, :text, if_not_exists: true

    create_table :triage_labels, if_not_exists: true do |t|
      t.string :key, null: false
      t.bigint :organization_id, null: false
      t.string :slug, null: false
      t.string :name, null: false
      t.text :description
      t.text :not_for
      t.string :color
      t.boolean :builtin, null: false, default: false
      t.boolean :enabled, null: false, default: true
      t.integer :position, null: false, default: 0
      t.timestamps
      t.index :key, unique: true
      t.index %i[organization_id slug], unique: true
    end

    add_foreign_key :triage_labels, :organizations, on_delete: :cascade, if_not_exists: true
  end
end
