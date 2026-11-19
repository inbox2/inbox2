# Disk activity. Never holds a sealed name. link_id gets its foreign key with
# disk_links (package 6).
class CreateDiskEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :disk_events, if_not_exists: true do |t|
      t.string :key, null: false
      t.bigint :organization_id, null: false
      t.bigint :node_id
      t.bigint :share_id
      t.bigint :actor_membership_id
      t.bigint :link_id
      t.string :action, null: false
      t.jsonb :detail, null: false, default: {}
      t.timestamps
      t.index :key, unique: true
      t.index %i[node_id created_at]
      t.index %i[share_id created_at]
    end
    add_foreign_key :disk_events, :organizations, if_not_exists: true
    add_foreign_key :disk_events, :disk_nodes, column: :node_id, on_delete: :nullify, if_not_exists: true
    add_foreign_key :disk_events, :disk_shares, column: :share_id, on_delete: :nullify, if_not_exists: true
    add_foreign_key :disk_events, :memberships, column: :actor_membership_id, on_delete: :nullify,
                                                if_not_exists: true
  end
end
