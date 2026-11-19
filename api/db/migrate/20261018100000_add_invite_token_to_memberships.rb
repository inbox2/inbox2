# Code audit 2026-10-18 (TODO 47.1): the invite email used to carry the
# membership's public key, which every teammate can read off the Team tab —
# so anyone could claim a new hire's account before they did. Invites now ride
# a hashed single-use token; the key grants nothing.
class AddInviteTokenToMemberships < ActiveRecord::Migration[8.1]
  def change
    add_column :memberships, :invite_token_digest, :string, if_not_exists: true
    add_index :memberships, :invite_token_digest, unique: true,
              where: "invite_token_digest IS NOT NULL", if_not_exists: true
  end
end
