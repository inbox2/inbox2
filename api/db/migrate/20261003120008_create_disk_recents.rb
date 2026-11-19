# Per-member recents: one row per (node, member).
class CreateDiskRecents < ActiveRecord::Migration[8.1]
  def change
    create_table :disk_recents, if_not_exists: true do |t|
      t.bigint :organization_id, null: false
      t.bigint :node_id, null: false
      t.bigint :membership_id, null: false
      t.timestamps
      t.index %i[node_id membership_id], unique: true
      t.index %i[membership_id created_at]
    end
    add_foreign_key :disk_recents, :organizations, if_not_exists: true
    add_foreign_key :disk_recents, :disk_nodes, column: :node_id, on_delete: :cascade, if_not_exists: true
    add_foreign_key :disk_recents, :memberships, on_delete: :cascade, if_not_exists: true
  end
end
