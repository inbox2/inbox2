# Disk shares: the folders on D:\ (docs/plans/disk-build.md section 4).
# root_node_id gets its foreign key in CreateDiskNodes, which creates the target.
class CreateDiskShares < ActiveRecord::Migration[8.1]
  def change
    create_table :disk_shares, if_not_exists: true do |t|
      t.string :key, null: false
      t.bigint :organization_id, null: false
      t.string :name, null: false
      t.string :icon
      t.string :color
      t.string :openness, null: false, default: "assigned"
      t.string :org_role, null: false, default: "view"
      t.bigint :root_node_id
      t.datetime :archived_at
      t.datetime :trashed_at
      t.bigint :trashed_by_membership_id
      t.datetime :purge_at
      t.timestamps
      t.index :key, unique: true
      t.index "organization_id, lower((name)::text)", unique: true, where: "(trashed_at IS NULL)",
                                                      name: "index_disk_shares_on_org_and_lower_name"
      t.index :root_node_id
    end
    add_foreign_key :disk_shares, :organizations, if_not_exists: true
    add_foreign_key :disk_shares, :memberships, column: :trashed_by_membership_id, on_delete: :nullify,
                                                if_not_exists: true
  end
end
