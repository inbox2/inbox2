# Disk pages (docs/plans/disk-build.md sections 4 and 9c): one row per page
# node. Unsealed pages keep the Yjs state and its markdown; sealed pages keep
# sealed_snapshot and update_seq (package 9). revision goes up on every save.
class CreateDiskPages < ActiveRecord::Migration[8.1]
  def change
    create_table :disk_pages, if_not_exists: true do |t|
      t.bigint :organization_id, null: false
      t.bigint :node_id, null: false
      t.binary :ydoc
      t.text :markdown
      t.binary :sealed_snapshot
      t.bigint :update_seq, null: false, default: 0
      t.integer :revision, null: false, default: 0
      t.timestamps
      t.index :node_id, unique: true
    end
    add_foreign_key :disk_pages, :organizations, if_not_exists: true
    add_foreign_key :disk_pages, :disk_nodes, column: :node_id, on_delete: :cascade, if_not_exists: true
  end
end
