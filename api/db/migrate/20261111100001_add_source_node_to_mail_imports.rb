# A person's own .mbox import (Settings › Account): the Disk file it reads from,
# so the job can fetch it again on a resume. Nulled when the file is deleted.
class AddSourceNodeToMailImports < ActiveRecord::Migration[8.1]
  def change
    add_column :mail_imports, :source_node_id, :bigint, if_not_exists: true
    add_foreign_key :mail_imports, :disk_nodes, column: :source_node_id, on_delete: :nullify, if_not_exists: true
  end
end
