# A named member's own access to a node and everything beneath it (view, edit).
class CreateDiskGrants < ActiveRecord::Migration[8.1]
  def change
    create_table :disk_grants, if_not_exists: true do |t|
      t.string :key, null: false
      t.bigint :organization_id, null: false
      t.bigint :node_id, null: false
      t.bigint :membership_id, null: false
      t.string :role, null: false
      t.bigint :granted_by_membership_id
      t.timestamps
      t.index :key, unique: true
      t.index %i[node_id membership_id], unique: true
      t.index :membership_id
    end
    add_foreign_key :disk_grants, :organizations, if_not_exists: true
    add_foreign_key :disk_grants, :disk_nodes, column: :node_id, on_delete: :cascade, if_not_exists: true
    add_foreign_key :disk_grants, :memberships, on_delete: :cascade, if_not_exists: true
    add_foreign_key :disk_grants, :memberships, column: :granted_by_membership_id, on_delete: :nullify,
                                                if_not_exists: true
  end
end
