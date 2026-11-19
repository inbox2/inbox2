# Disk nodes: every folder, file and page, on C:\ (custodian_membership_id) or
# in a share (share_id). Carries the sealed, folder-integrity and trash columns
# now so later packages do not re-migrate it (docs/plans/disk-build.md section 4).
# current_version_id gets its foreign key with disk_versions (package 2).
class CreateDiskNodes < ActiveRecord::Migration[8.1]
  def change
    create_table :disk_nodes, if_not_exists: true do |t|
      t.string :key, null: false
      t.bigint :organization_id, null: false
      t.bigint :share_id
      t.bigint :custodian_membership_id
      t.bigint :parent_id
      t.string :kind, null: false
      t.string :name
      t.string :mime
      t.boolean :sealed, null: false, default: false
      t.bigint :seal_scope_node_id
      t.integer :key_epoch
      t.binary :metadata_ciphertext
      t.integer :scope_epoch
      t.binary :scope_parent_wrapped_key
      t.bigint :current_version_id
      t.bigint :size_bytes, null: false, default: 0
      t.bigint :created_by_membership_id
      t.bigint :modified_by_membership_id
      t.datetime :content_modified_at
      t.integer :listing_revision, null: false, default: 0
      t.binary :listing_digest
      t.bigint :listing_signer_membership_id
      t.binary :listing_signature
      t.datetime :trashed_at
      t.bigint :trashed_by_membership_id
      t.boolean :trash_root, null: false, default: false
      t.bigint :original_parent_id
      t.timestamps
      t.index :key, unique: true
      t.index :share_id, unique: true, where: "((parent_id IS NULL) AND (share_id IS NOT NULL))",
                         name: "index_disk_nodes_one_root_per_share"
      t.index :custodian_membership_id, unique: true,
                                        where: "((parent_id IS NULL) AND (custodian_membership_id IS NOT NULL))",
                                        name: "index_disk_nodes_one_root_per_custodian"
      t.index "parent_id, lower((name)::text)", unique: true,
                                                where: "((name IS NOT NULL) AND (trashed_at IS NULL))",
                                                name: "index_disk_nodes_unique_name_in_folder"
      t.index "organization_id, parent_id, kind, lower((name)::text)", name: "index_disk_nodes_on_org_parent_kind_name"
      t.index %i[organization_id parent_id content_modified_at], name: "index_disk_nodes_on_org_parent_modified"
      t.index %i[organization_id parent_id size_bytes], name: "index_disk_nodes_on_org_parent_size"
      t.index %i[organization_id trashed_at], where: "trash_root", name: "index_disk_nodes_on_org_trash"
      t.index :seal_scope_node_id
      t.index :share_id
      t.index :custodian_membership_id
      t.index :parent_id
      t.index "lower((name)::text) gin_trgm_ops", using: :gin, name: "index_disk_nodes_on_name_trgm"
      t.check_constraint "(sealed AND name IS NULL AND mime IS NULL) OR (NOT sealed AND metadata_ciphertext IS NULL)",
                         name: "disk_nodes_sealed_identity"
      t.check_constraint "(share_id IS NULL) <> (custodian_membership_id IS NULL)", name: "disk_nodes_one_drive"
    end
    add_foreign_key :disk_nodes, :organizations, if_not_exists: true
    add_foreign_key :disk_nodes, :disk_shares, column: :share_id, if_not_exists: true
    # No ON DELETE: a member's C:\ is reassigned on offboarding (package 13), never dropped with them.
    add_foreign_key :disk_nodes, :memberships, column: :custodian_membership_id, if_not_exists: true
    add_foreign_key :disk_nodes, :disk_nodes, column: :parent_id, if_not_exists: true
    add_foreign_key :disk_nodes, :disk_nodes, column: :seal_scope_node_id, if_not_exists: true
    add_foreign_key :disk_nodes, :disk_nodes, column: :original_parent_id, on_delete: :nullify, if_not_exists: true
    add_foreign_key :disk_nodes, :memberships, column: :created_by_membership_id, on_delete: :nullify,
                                               if_not_exists: true
    add_foreign_key :disk_nodes, :memberships, column: :modified_by_membership_id, on_delete: :nullify,
                                               if_not_exists: true
    add_foreign_key :disk_nodes, :memberships, column: :listing_signer_membership_id, on_delete: :nullify,
                                               if_not_exists: true
    add_foreign_key :disk_nodes, :memberships, column: :trashed_by_membership_id, on_delete: :nullify,
                                               if_not_exists: true
    add_foreign_key :disk_shares, :disk_nodes, column: :root_node_id, on_delete: :nullify, if_not_exists: true
  end
end
