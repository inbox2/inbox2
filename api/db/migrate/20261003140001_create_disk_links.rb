# Disk public links (docs/plans/disk-build.md section 4). The token is stored
# only as its SHA-256. An unsealed link's password is a bcrypt hash in
# password_verifier_digest; the sealed columns (version_id, kdf_*,
# wrapped_payload, wrap_key_sealed) arrive now so package 9 does not re-migrate.
# Also gives disk_events.link_id its foreign key.
class CreateDiskLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :disk_links, if_not_exists: true do |t|
      t.string :key, null: false
      t.bigint :organization_id, null: false
      t.bigint :node_id, null: false
      t.bigint :version_id
      t.string :token_digest, null: false
      t.string :password_verifier_digest
      t.integer :kdf_version
      t.binary :kdf_salt
      t.binary :wrapped_payload
      t.binary :wrap_key_sealed
      t.datetime :expires_at
      t.boolean :hide_download, null: false, default: false
      t.bigint :created_by_membership_id
      t.datetime :revoked_at
      t.datetime :last_used_at
      t.timestamps
      t.index :key, unique: true
      t.index :token_digest, unique: true
      t.index :node_id
    end
    add_foreign_key :disk_links, :organizations, if_not_exists: true
    add_foreign_key :disk_links, :disk_nodes, column: :node_id, on_delete: :cascade, if_not_exists: true
    add_foreign_key :disk_links, :disk_versions, column: :version_id, on_delete: :cascade, if_not_exists: true
    add_foreign_key :disk_links, :memberships, column: :created_by_membership_id, on_delete: :nullify,
                                               if_not_exists: true
    add_index :disk_events, :link_id, if_not_exists: true
    add_foreign_key :disk_events, :disk_links, column: :link_id, on_delete: :nullify, if_not_exists: true
  end
end
