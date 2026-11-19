# Per-member stars: one row per (node, member).
class CreateDiskStars < ActiveRecord::Migration[8.1]
  def change
    create_table :disk_stars, if_not_exists: true do |t|
      t.bigint :organization_id, null: false
      t.bigint :node_id, null: false
      t.bigint :membership_id, null: false
      t.timestamps
      t.index %i[node_id membership_id], unique: true
      t.index %i[membership_id created_at]
    end
    add_foreign_key :disk_stars, :organizations, if_not_exists: true
    add_foreign_key :disk_stars, :disk_nodes, column: :node_id, on_delete: :cascade, if_not_exists: true
    add_foreign_key :disk_stars, :memberships, on_delete: :cascade, if_not_exists: true
  end
end
