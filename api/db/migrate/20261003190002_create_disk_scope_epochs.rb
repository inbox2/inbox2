# One row per epoch of a sealed scope (docs/plans/disk-build.md section 6.5):
# previous_key_wrapped is the prior epoch's key under this epoch's key, null
# for epoch 1, so a holder of the current key walks back to every older one.
class CreateDiskScopeEpochs < ActiveRecord::Migration[8.1]
  def change
    create_table :disk_scope_epochs, if_not_exists: true do |t|
      t.bigint :organization_id, null: false
      t.bigint :scope_node_id, null: false
      t.integer :epoch, null: false
      t.binary :previous_key_wrapped
      t.bigint :created_by_membership_id
      t.timestamps
      t.index %i[scope_node_id epoch], unique: true
    end
    add_foreign_key :disk_scope_epochs, :organizations, if_not_exists: true
    add_foreign_key :disk_scope_epochs, :disk_nodes, column: :scope_node_id, on_delete: :cascade, if_not_exists: true
    add_foreign_key :disk_scope_epochs, :memberships, column: :created_by_membership_id, on_delete: :nullify,
                                                      if_not_exists: true
  end
end
