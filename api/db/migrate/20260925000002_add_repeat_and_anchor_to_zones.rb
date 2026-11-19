# Zones, round two (docs/Calendar.md "Zones"): a repeat rule (expanded into
# occurrences on read, in the zone's own time zone) and an optional anchor that
# keeps a prep zone glued to its meeting when the meeting moves.
class AddRepeatAndAnchorToZones < ActiveRecord::Migration[8.1]
  def change
    add_column :zones, :repeat, :string, null: false, default: "none", if_not_exists: true
    add_column :zones, :repeat_until, :date, if_not_exists: true
    add_column :zones, :time_zone, :string, if_not_exists: true
    add_column :zones, :anchor_event_id, :string, if_not_exists: true
    add_column :zones, :anchor_minutes, :integer, if_not_exists: true
  end
end
