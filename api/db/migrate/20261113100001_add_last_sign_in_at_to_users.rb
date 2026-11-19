# When a person last signed in (ApplicationController#create_session_for). The
# Pushleft Admin page lists people on it, newest first, and polls that list:
# the index is in that order so the poll reads one page of it.
class AddLastSignInAtToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :last_sign_in_at, :datetime, if_not_exists: true
    add_index :users, %i[last_sign_in_at id], order: { last_sign_in_at: "DESC NULLS LAST", id: :desc },
      if_not_exists: true
    # The best answer for people who signed in before this column: their newest
    # session that still exists (signing out deletes it).
    execute <<~SQL
      UPDATE users SET last_sign_in_at = s.at
      FROM (SELECT user_id, MAX(created_at) AS at FROM sessions GROUP BY user_id) s
      WHERE s.user_id = users.id AND users.last_sign_in_at IS NULL
    SQL
  end

  def down
    remove_column :users, :last_sign_in_at, if_exists: true
  end
end
