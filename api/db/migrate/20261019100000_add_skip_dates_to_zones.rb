# Deleting one occurrence of a repeating zone (docs/Calendar.md "Zones"): the
# zone's local dates that the expansion skips.
class AddSkipDatesToZones < ActiveRecord::Migration[8.1]
  def change
    add_column :zones, :skip_dates, :date, array: true, default: [], null: false, if_not_exists: true
  end
end
