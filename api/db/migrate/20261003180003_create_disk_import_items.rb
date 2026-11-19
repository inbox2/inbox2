# One source item per target: a re-run into the same target finds the row for
# a source id and updates its node, so nothing is duplicated (build guide 4).
class CreateDiskImportItems < ActiveRecord::Migration[8.1]
  def change
    create_table :disk_import_items, if_not_exists: true do |t|
      t.bigint :organization_id, null: false
      t.bigint :import_id, null: false
      t.string :provider, null: false
      t.bigint :target_node_id, null: false
      t.string :source_id, null: false
      t.string :name
      t.datetime :source_modified_at
      t.bigint :node_id
      t.string :status, null: false
      t.string :reason
      t.jsonb :detail, null: false, default: {}
      t.timestamps
      t.index %i[organization_id provider target_node_id source_id], unique: true,
                                                                     name: "index_disk_import_items_on_source"
      t.index %i[import_id status]
    end
    add_foreign_key :disk_import_items, :organizations, if_not_exists: true
    add_foreign_key :disk_import_items, :disk_imports, column: :import_id, on_delete: :cascade, if_not_exists: true
    add_foreign_key :disk_import_items, :disk_nodes, column: :target_node_id, on_delete: :cascade, if_not_exists: true
    add_foreign_key :disk_import_items, :disk_nodes, column: :node_id, on_delete: :nullify, if_not_exists: true
  end
end
