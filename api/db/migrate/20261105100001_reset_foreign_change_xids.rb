# The Pushleft move (2026-11-05) restored a dump into a fresh cluster, which
# restarts transaction ids. Rows kept the old cluster's change_xid (up to ~40M),
# which the new one won't reach for weeks: a tombstone's old xid became the
# expiry watermark (every pull "expired" → a full reconcile on every sync) and
# old rows would resurface in pulls as the xids climbed past them. Those xids
# mean nothing here; 0 puts the rows behind every cursor, where backfill and
# reconcile already cover them. Triggers off so the update isn't re-stamped as
# a change of every row. A no-op on a database that was never restored.
class ResetForeignChangeXids < ActiveRecord::Migration[8.1]
  TABLES = %w[conversations messages notes sync_tombstones].freeze

  def up
    next_xid = select_value("SELECT pg_snapshot_xmax(pg_current_snapshot())::text::bigint").to_i
    TABLES.each do |t|
      execute "ALTER TABLE #{t} DISABLE TRIGGER USER"
      execute "UPDATE #{t} SET change_xid = 0 WHERE change_xid > #{next_xid}"
      execute "ALTER TABLE #{t} ENABLE TRIGGER USER"
    end
  end

  def down; end
end
