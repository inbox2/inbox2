# MX sync change tracking (docs/MX-Sync.md): a version + writing-transaction stamp
# on every synced row, a tombstone table, and the triggers that maintain them.
#
# Existing rows are deliberately NOT seeded — no boot-time UPDATE across messages.
# NULL means "unchanged since sync existed"; clients get those rows from backfill.
#
# Runs at pod boot (db:prepare), so the indexes are built CONCURRENTLY: a plain
# build holds a write-blocking lock on messages for the whole scan. That forces
# the migration out of a DDL transaction; every statement is idempotent instead,
# so a half-applied run simply re-runs — including an interrupted concurrent
# build, whose INVALID leftover `if_not_exists` would otherwise accept.
class AddMxSyncChangeTracking < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    %i[conversations messages notes].each do |table|
      add_column table, :change_seq, :bigint, if_not_exists: true
      add_column table, :change_xid, :bigint, if_not_exists: true
      drop_invalid_index("index_#{table}_on_sync_cursor")
      add_index table, %i[organization_id change_xid change_seq], where: "change_seq IS NOT NULL",
        name: "index_#{table}_on_sync_cursor", if_not_exists: true, algorithm: :concurrently
    end

    create_table :sync_tombstones, if_not_exists: true do |t|
      t.bigint :organization_id, null: false
      t.string :record_type, null: false
      t.string :record_key, null: false
      t.string :parent_key
      t.bigint :change_seq, null: false
      t.bigint :change_xid, null: false
      t.datetime :created_at, null: false
      t.index %i[organization_id change_xid change_seq], name: "index_sync_tombstones_on_sync_cursor"
      t.index %i[organization_id created_at]
    end

    SyncTriggers.ensure!(connection)
  end

  def drop_invalid_index(name)
    invalid = select_value(<<~SQL)
      SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      WHERE c.relname = #{connection.quote(name)} AND NOT i.indisvalid
    SQL
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{quote_column_name(name)}") if invalid
  end

  def down
    SyncTriggers.remove!(connection)
    drop_table :sync_tombstones, if_exists: true
    %i[conversations messages notes].each do |table|
      remove_index table, name: "index_#{table}_on_sync_cursor", if_exists: true
      remove_column table, :change_seq, if_exists: true
      remove_column table, :change_xid, if_exists: true
    end
  end
end
