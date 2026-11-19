# A zone that counts as busy (docs/Calendar.md "Zones"): off by default, so a
# zone stays a soft label unless the member ticks "Block this time".
class AddBlocksToZones < ActiveRecord::Migration[8.1]
  def change
    add_column :zones, :blocks, :boolean, default: false, null: false, if_not_exists: true
  end
end
