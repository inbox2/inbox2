# Per-member "done" for Lore's personal buckets on a shared MX domain
# (docs/TODO.md 48.11, docs/MX-Sync.md). A row hides the thread from that member's
# Lore only; the thread itself, and everyone else's Lore, are untouched.
class CreateLoreMemberDones < ActiveRecord::Migration[8.1]
  def up
    create_table :lore_member_dones, if_not_exists: true do |t|
      t.references :conversation, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :membership, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
      t.index %i[conversation_id membership_id], unique: true
    end
    # The new child table bumps its thread's change_seq (SyncTriggers::BUMPS).
    SyncTriggers.ensure!(connection)
  end

  def down
    drop_table :lore_member_dones, if_exists: true
  end
end
