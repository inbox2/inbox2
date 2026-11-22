# Disk sync feed (docs/Disk-Sync.md): a version + writing-transaction stamp on
# disk_nodes, an event table for deletes and access changes, and the triggers
# that maintain them (Disk::SyncTriggers). Existing nodes are stamped here, so
# every node has a version from the start (disk_nodes is small next to messages).
# Idempotent throughout: a fresh install already has the columns and table from
# 20260522000001.
class AddDiskSyncTracking < ActiveRecord::Migration[8.1]
  def up
    add_column :disk_nodes, :change_seq, :bigint, if_not_exists: true
    add_column :disk_nodes, :change_xid, :bigint, if_not_exists: true
    add_index :disk_nodes, %i[organization_id change_xid change_seq], name: "index_disk_nodes_on_sync_cursor",
      if_not_exists: true
    add_column :disk_uploads, :base_version_key, :string, if_not_exists: true

    create_table :disk_sync_events, if_not_exists: true do |t|
      t.bigint :organization_id, null: false
      t.string :kind, null: false
      t.string :node_key
      t.bigint :change_seq, null: false
      t.bigint :change_xid, null: false
      t.datetime :created_at, null: false
      t.index %i[organization_id change_xid change_seq], name: "index_disk_sync_events_on_sync_cursor"
      t.index %i[organization_id created_at]
    end

    Disk::SyncTriggers.ensure!(connection)
    execute("UPDATE disk_nodes SET change_seq = change_seq WHERE change_seq IS NULL")
  end

  def down
    Disk::SyncTriggers.remove!(connection)
    drop_table :disk_sync_events, if_exists: true
    remove_column :disk_uploads, :base_version_key, if_exists: true
    remove_index :disk_nodes, name: "index_disk_nodes_on_sync_cursor", if_exists: true
    remove_column :disk_nodes, :change_seq, if_exists: true
    remove_column :disk_nodes, :change_xid, if_exists: true
  end
end
