# room0 (the 3D multiplayer office) moved out of inbox2 to its own project.
# DESTRUCTIVE on prod: drops the room0 whiteboards and voice-note rows.
# Guards (if_exists) so it no-ops on a fresh install, where the initial
# schema no longer creates any of this.
class DropRoom0 < ActiveRecord::Migration[8.1]
  def up
    drop_table :room0_boards, if_exists: true
    drop_table :room_voice_notes, if_exists: true
    remove_column :organizations, :room0_enabled, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
