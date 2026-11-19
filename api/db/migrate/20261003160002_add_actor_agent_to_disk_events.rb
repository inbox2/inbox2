# Activity names the agent that acted (docs/plans/disk-build.md section 9c).
class AddActorAgentToDiskEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :disk_events, :actor_agent_id, :bigint, if_not_exists: true
    add_index :disk_events, :actor_agent_id, if_not_exists: true
    add_foreign_key :disk_events, :agents, column: :actor_agent_id, on_delete: :nullify, if_not_exists: true
  end
end
