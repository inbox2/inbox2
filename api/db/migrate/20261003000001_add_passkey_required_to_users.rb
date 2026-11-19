# Opt-in "require a passkey to sign in": with it on, a correct password alone no
# longer signs the account in — the passkey (or a TOTP code) has to follow.
class AddPasskeyRequiredToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :passkey_required, :boolean, null: false, default: false, if_not_exists: true
  end
end
