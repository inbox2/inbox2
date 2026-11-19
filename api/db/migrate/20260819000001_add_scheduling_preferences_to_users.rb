# Per-person scheduling preferences (docs/Calendar.md): the working day the
# scheduling assistant shades and ranks suggestions against, and an out-of-office
# period that makes someone busy without them having to block their own calendar.
#
# Its own file so production actually migrates: prod already recorded
# 20260522000001, so folding these columns only into the initial schema would
# never reach it — and a serializer exposing a column prod lacks 500s every
# account request (the 2026-07-30 meeting-invite incident). The columns are ALSO
# in the initial schema so a fresh install still gets everything from one file;
# `if_not_exists` makes this a no-op there.
#
# `working_hours` is jsonb and nullable: NULL means "never set", which falls back
# to the org default in User#effective_working_hours rather than to an empty day.
class AddSchedulingPreferencesToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :working_hours, :jsonb, if_not_exists: true
    add_column :users, :out_of_office_start, :datetime, if_not_exists: true
    add_column :users, :out_of_office_end, :datetime, if_not_exists: true
    add_column :users, :out_of_office_message, :string, if_not_exists: true
  end
end
