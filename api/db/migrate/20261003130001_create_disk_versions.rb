# Disk file versions (docs/plans/disk-build.md section 4). storage_key is an
# opaque random id, never derived from a name. The sealed columns (key_epoch,
# wrapped_key, manifest_ciphertext, chunk_bytes) arrive now so package 9 does
# not re-migrate. Also gives disk_nodes.current_version_id its foreign key:
# no ON DELETE, so a node's current version can never be deleted under it.
class CreateDiskVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :disk_versions, if_not_exists: true do |t|
      t.string :key, null: false
      t.bigint :organization_id, null: false
      t.bigint :node_id, null: false
      t.integer :number, null: false
      t.string :storage_key, null: false
      t.bigint :size_bytes, null: false, default: 0
      t.integer :chunk_bytes
      t.string :sha256
      t.integer :key_epoch
      t.binary :wrapped_key
      t.binary :manifest_ciphertext
      t.string :thumbnail_storage_key
      t.string :rendition_storage_key
      t.bigint :author_membership_id
      t.datetime :expires_at
      t.timestamps
      t.index :key, unique: true
      t.index :storage_key, unique: true
      t.index %i[node_id number], unique: true
      t.index %i[node_id created_at]
      t.index :expires_at
    end
    add_foreign_key :disk_versions, :organizations, if_not_exists: true
    add_foreign_key :disk_versions, :disk_nodes, column: :node_id, on_delete: :cascade, if_not_exists: true
    add_foreign_key :disk_versions, :memberships, column: :author_membership_id, on_delete: :nullify,
                                                  if_not_exists: true
    add_index :disk_nodes, :current_version_id, if_not_exists: true
    add_foreign_key :disk_nodes, :disk_versions, column: :current_version_id, if_not_exists: true
  end
end
