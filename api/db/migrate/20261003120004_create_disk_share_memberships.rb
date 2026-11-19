# Who belongs to a share and at which role (view, edit, manage).
class CreateDiskShareMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :disk_share_memberships, if_not_exists: true do |t|
      t.bigint :organization_id, null: false
      t.bigint :share_id, null: false
      t.bigint :membership_id, null: false
      t.string :role, null: false
      t.timestamps
      t.index %i[share_id membership_id], unique: true, name: "index_disk_share_memberships_on_share_and_membership"
      t.index :membership_id
    end
    add_foreign_key :disk_share_memberships, :organizations, if_not_exists: true
    add_foreign_key :disk_share_memberships, :disk_shares, column: :share_id, on_delete: :cascade, if_not_exists: true
    add_foreign_key :disk_share_memberships, :memberships, on_delete: :cascade, if_not_exists: true
  end
end
