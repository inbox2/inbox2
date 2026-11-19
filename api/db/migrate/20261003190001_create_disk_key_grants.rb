# A sealed scope's key, sealed to one key holder for one epoch
# (docs/plans/disk-build.md section 6.4). The server cannot open sealed_key.
# signature stays null until step two (6.12). membership_id has no ON DELETE:
# a holder leaving must go through Disk::KeyGrant.freeze_holders!, which marks
# the scope rotation_due, so a delete that skips it fails instead of hiding the
# key left behind.
class CreateDiskKeyGrants < ActiveRecord::Migration[8.1]
  def change
    create_table :disk_key_grants, if_not_exists: true do |t|
      t.bigint :organization_id, null: false
      t.string :key, null: false
      t.bigint :scope_node_id, null: false
      t.bigint :membership_id, null: false
      t.integer :epoch, null: false
      t.binary :sealed_key, null: false
      t.bigint :granted_by_membership_id
      t.binary :signature
      t.timestamps
      t.index :key, unique: true
      t.index %i[scope_node_id membership_id epoch], unique: true, name: "index_disk_key_grants_on_scope_member_epoch"
      t.index :membership_id
    end
    add_foreign_key :disk_key_grants, :organizations, if_not_exists: true
    add_foreign_key :disk_key_grants, :disk_nodes, column: :scope_node_id, on_delete: :cascade, if_not_exists: true
    add_foreign_key :disk_key_grants, :memberships, if_not_exists: true
    add_foreign_key :disk_key_grants, :memberships, column: :granted_by_membership_id, on_delete: :nullify,
                                                    if_not_exists: true
  end
end
