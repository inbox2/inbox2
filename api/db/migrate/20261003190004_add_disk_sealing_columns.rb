# Sealing step one (docs/plans/disk-build.md section 6):
# - disk_nodes.rotation_due: on a scope root, writes are refused until a rotate (6.7)
# - disk_nodes.pending_until: a staged node, invisible except to its creator
#   until switched in, purged by Disk::ExpireUploadsJob past this time (6.8)
# - disk_nodes.switched_at: a source replaced by a staged node, purge pending (6.8)
# - disk_pages / disk_page_versions: the epoch and seq a sealed snapshot covers (6.10)
# - disk_uploads.staged: the upload's new node is created staged
class AddDiskSealingColumns < ActiveRecord::Migration[8.1]
  def change
    add_column :disk_nodes, :rotation_due, :boolean, default: false, null: false, if_not_exists: true
    add_column :disk_nodes, :pending_until, :datetime, if_not_exists: true
    add_column :disk_nodes, :switched_at, :datetime, if_not_exists: true
    add_index :disk_nodes, :pending_until, where: "pending_until IS NOT NULL", if_not_exists: true
    add_index :disk_nodes, :switched_at, where: "switched_at IS NOT NULL", if_not_exists: true
    add_column :disk_pages, :snapshot_epoch, :integer, if_not_exists: true
    add_column :disk_pages, :snapshot_seq, :bigint, if_not_exists: true
    add_column :disk_page_versions, :sealed_snapshot, :binary, if_not_exists: true
    add_column :disk_page_versions, :snapshot_epoch, :integer, if_not_exists: true
    add_column :disk_page_versions, :snapshot_seq, :bigint, if_not_exists: true
    add_column :disk_uploads, :staged, :boolean, default: false, null: false, if_not_exists: true
  end
end
