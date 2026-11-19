# Page history (spec F6 "Pages have version history like files"). A snapshot
# of the page at a revision; saves by the same person within a few minutes
# update the newest snapshot instead of adding one.
class CreateDiskPageVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :disk_page_versions, if_not_exists: true do |t|
      t.bigint :organization_id, null: false
      t.bigint :node_id, null: false
      t.integer :revision, null: false
      t.binary :ydoc
      t.text :markdown
      t.bigint :author_membership_id
      t.timestamps
      t.index %i[node_id revision], unique: true
      t.index %i[node_id created_at]
    end
    add_foreign_key :disk_page_versions, :organizations, if_not_exists: true
    add_foreign_key :disk_page_versions, :disk_nodes, column: :node_id, on_delete: :cascade, if_not_exists: true
    add_foreign_key :disk_page_versions, :memberships, column: :author_membership_id, on_delete: :nullify,
                                                       if_not_exists: true
  end
end
