# Calendar zones (docs/Calendar.md "Zones"): a member's own soft focus blocks.
# Unlike blocked time they never count as busy — free/busy ignores them — they
# only mark the calendar and raise a "you're in the zone" card when they start.
# User-scoped, not org-scoped: one person's zones follow them across orgs and
# every client (web, desktop, iOS, Android).
class CreateZones < ActiveRecord::Migration[8.1]
  def change
    create_table :zone_categories, if_not_exists: true do |t|
      t.bigint :user_id, null: false
      t.string :key, null: false
      t.string :name, null: false
      t.string :color, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
      t.index :key, unique: true
      t.index %i[user_id position], name: "index_zone_categories_on_user_position"
    end

    create_table :zones, if_not_exists: true do |t|
      t.bigint :user_id, null: false
      t.bigint :zone_category_id
      t.string :key, null: false
      t.string :name, null: false
      t.text :note
      t.datetime :start_at, null: false
      t.datetime :end_at, null: false
      t.boolean :notify, null: false, default: true
      t.timestamps
      t.index :key, unique: true
      t.index %i[user_id start_at], name: "index_zones_on_user_start"
      t.index :zone_category_id
    end

    add_foreign_key :zone_categories, :users, if_not_exists: true
    add_foreign_key :zones, :users, if_not_exists: true
    add_foreign_key :zones, :zone_categories, on_delete: :nullify, if_not_exists: true
  end
end
