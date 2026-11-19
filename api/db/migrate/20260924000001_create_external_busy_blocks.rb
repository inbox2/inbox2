# Busy-only blocks a member's devices upload from their local (Gmail/Office365)
# calendars (docs/Calendar.md "External busy"): bare start/end, no titles, so a
# meet link and colleagues' free/busy see meetings the server never syncs.
class CreateExternalBusyBlocks < ActiveRecord::Migration[8.1]
  def change
    create_table :external_busy_blocks, if_not_exists: true do |t|
      t.bigint :organization_id, null: false
      t.bigint :membership_id, null: false
      t.string :source, null: false
      t.datetime :start_at, null: false
      t.datetime :end_at, null: false
      t.timestamps
      t.index %i[membership_id source], name: "index_external_busy_blocks_on_membership_source"
      t.index %i[organization_id start_at end_at], name: "index_external_busy_blocks_on_org_range"
    end
    add_foreign_key :external_busy_blocks, :organizations, if_not_exists: true
    add_foreign_key :external_busy_blocks, :memberships, if_not_exists: true
  end
end
