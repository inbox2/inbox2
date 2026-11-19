# Disk upload reservations (docs/plans/disk-build.md sections 4 and 8).
# node_key and version_key are the public ids the node and version will get on
# completion, handed out at reserve time because a sealed client binds its
# chunks, manifest and metadata to them before the first byte is sent.
# wrapped_key and manifest_ciphertext are held here between complete and the
# version insert so the reconcile job can finish an interrupted completion.
class CreateDiskUploads < ActiveRecord::Migration[8.1]
  def change
    create_table :disk_uploads, if_not_exists: true do |t|
      t.string :key, null: false
      t.bigint :organization_id, null: false
      t.bigint :membership_id, null: false
      t.bigint :parent_id
      t.bigint :node_id
      t.string :node_key, null: false
      t.string :version_key, null: false
      t.string :intended_name
      t.binary :intended_metadata_ciphertext
      t.string :storage_key, null: false
      t.string :multipart_upload_id
      t.bigint :declared_bytes, null: false
      t.bigint :part_bytes, null: false
      t.integer :chunk_bytes
      t.boolean :sealed, null: false, default: false
      t.integer :key_epoch
      t.binary :wrapped_key
      t.binary :manifest_ciphertext
      t.string :sha256
      t.string :state, null: false, default: "reserved"
      t.string :idempotency_key
      t.datetime :expires_at, null: false
      t.timestamps
      t.index :key, unique: true
      t.index :storage_key, unique: true
      t.index %i[membership_id idempotency_key], unique: true
      t.index %i[state expires_at]
      t.check_constraint "sealed AND intended_name IS NULL OR NOT sealed AND intended_metadata_ciphertext IS NULL",
                         name: "disk_uploads_sealed_identity"
    end
    add_foreign_key :disk_uploads, :organizations, if_not_exists: true
    add_foreign_key :disk_uploads, :memberships, on_delete: :cascade, if_not_exists: true
    add_foreign_key :disk_uploads, :disk_nodes, column: :parent_id, on_delete: :nullify, if_not_exists: true
    add_foreign_key :disk_uploads, :disk_nodes, column: :node_id, on_delete: :nullify, if_not_exists: true
  end
end
