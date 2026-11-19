# An agent's reach into Disk (docs/plans/disk-build.md section 9c): a share or
# folder an owner or admin granted it, at view or edit. Disk::Access caps it by
# the granter's own current role.
class CreateDiskAgentGrants < ActiveRecord::Migration[8.1]
  def change
    create_table :disk_agent_grants, if_not_exists: true do |t|
      t.bigint :organization_id, null: false
      t.bigint :agent_id, null: false
      t.bigint :node_id, null: false
      t.string :role, null: false
      t.bigint :granted_by_membership_id
      t.timestamps
      t.index %i[agent_id node_id], unique: true
      t.index :node_id
    end
    add_foreign_key :disk_agent_grants, :organizations, if_not_exists: true
    add_foreign_key :disk_agent_grants, :agents, on_delete: :cascade, if_not_exists: true
    add_foreign_key :disk_agent_grants, :disk_nodes, column: :node_id, on_delete: :cascade, if_not_exists: true
    add_foreign_key :disk_agent_grants, :memberships, column: :granted_by_membership_id, on_delete: :nullify,
                                                      if_not_exists: true
  end
end
