# A zone card clicked away (docs/Calendar.md "Zones"), kept on the server so
# "Done" on one device clears the card on every other. One row per occurrence;
# rows expire with their zone.
class CreateZoneDismissals < ActiveRecord::Migration[8.1]
  def change
    create_table :zone_dismissals, if_not_exists: true do |t|
      t.bigint :user_id, null: false
      t.string :occurrence_id, null: false
      t.datetime :end_at, null: false
      t.timestamps
      t.index %i[user_id occurrence_id], unique: true, name: "index_zone_dismissals_on_user_occurrence"
      t.index %i[user_id end_at], name: "index_zone_dismissals_on_user_end"
    end
    add_foreign_key :zone_dismissals, :users, if_not_exists: true
  end
end
