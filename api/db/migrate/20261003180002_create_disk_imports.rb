# One import run: one source space (a personal drive, a shared drive or
# library, a team folder) into one target folder or share (spec F10).
class CreateDiskImports < ActiveRecord::Migration[8.1]
  def change
    create_table :disk_imports, if_not_exists: true do |t|
      t.string :key, null: false
      t.bigint :organization_id, null: false
      t.bigint :membership_id, null: false
      t.bigint :connection_id
      t.bigint :owner_membership_id
      t.string :provider, null: false
      t.string :space_kind, null: false
      t.string :space_id
      t.string :space_name
      t.string :source_email
      t.bigint :target_node_id
      t.bigint :share_id
      t.string :state, null: false
      t.string :pause_reason
      t.text :cursor
      t.jsonb :counts, null: false, default: {}
      t.jsonb :report, null: false, default: {}
      t.text :error
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
      t.index :key, unique: true
      t.index %i[organization_id created_at]
      t.index :target_node_id
    end
    add_foreign_key :disk_imports, :organizations, if_not_exists: true
    add_foreign_key :disk_imports, :memberships, on_delete: :cascade, if_not_exists: true
    add_foreign_key :disk_imports, :memberships, column: :owner_membership_id, on_delete: :nullify, if_not_exists: true
    add_foreign_key :disk_imports, :disk_import_connections, column: :connection_id, on_delete: :nullify, if_not_exists: true
    add_foreign_key :disk_imports, :disk_nodes, column: :target_node_id, on_delete: :nullify, if_not_exists: true
    add_foreign_key :disk_imports, :disk_shares, column: :share_id, on_delete: :nullify, if_not_exists: true
  end
end
