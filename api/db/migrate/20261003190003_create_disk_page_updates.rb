# Stored updates of a sealed page (docs/plans/disk-build.md section 6.10), in
# page-wide seq order, each an envelope under the scope's page key for its
# epoch. Updates at or below the latest snapshot's seq are deleted.
class CreateDiskPageUpdates < ActiveRecord::Migration[8.1]
  def change
    create_table :disk_page_updates, if_not_exists: true do |t|
      t.bigint :organization_id, null: false
      t.bigint :node_id, null: false
      t.integer :epoch, null: false
      t.bigint :seq, null: false
      t.binary :ciphertext, null: false
      t.datetime :created_at, null: false
      t.index %i[node_id seq], unique: true
    end
    add_foreign_key :disk_page_updates, :organizations, if_not_exists: true
    add_foreign_key :disk_page_updates, :disk_nodes, column: :node_id, on_delete: :cascade, if_not_exists: true
  end
end
