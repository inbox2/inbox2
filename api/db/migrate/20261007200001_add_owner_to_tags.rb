# Private labels (docs/plans/mail-import.md D11/D12, 2026-10-07): a tag with a
# membership belongs to that member alone; without one it is the org's. Names
# are unique per owner, so Ana's "Clients" and the team's "Clients" coexist.
class AddOwnerToTags < ActiveRecord::Migration[8.1]
  def up
    add_column :tags, :membership_id, :bigint, if_not_exists: true
    add_index :tags, :membership_id, where: "membership_id IS NOT NULL", if_not_exists: true
    add_foreign_key :tags, :memberships, on_delete: :cascade unless foreign_key_exists?(:tags, :memberships)
    add_index :tags, "organization_id, COALESCE(membership_id, (0)::bigint), name",
              name: "index_tags_on_org_owner_and_name", unique: true, if_not_exists: true
    remove_index :tags, name: "index_tags_on_organization_id_and_name", if_exists: true
  end

  def down
    add_index :tags, %i[organization_id name], name: "index_tags_on_organization_id_and_name", unique: true, if_not_exists: true
    remove_index :tags, name: "index_tags_on_org_owner_and_name", if_exists: true
    remove_column :tags, :membership_id, if_exists: true
  end
end
