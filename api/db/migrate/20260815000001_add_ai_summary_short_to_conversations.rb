# The generated one-line summary shown as the list-row preview (the MX half of
# what the local-channel core writes into SQLite as `ai_summary_short`).
#
# Its own file so production actually migrates: prod already recorded
# 20260522000001, so folding the column only into the initial schema would never
# reach it — and a serializer exposing a column prod lacks 500s every
# conversation request (the 2026-07-30 meeting-invite incident). The column is
# ALSO in the initial schema so a fresh install still gets everything from one
# file; `if_not_exists` makes this a no-op there.
class AddAiSummaryShortToConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :ai_summary_short, :string, if_not_exists: true
  end
end
