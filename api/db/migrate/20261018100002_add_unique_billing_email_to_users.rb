# Code audit 2026-10-18 (TODO 47.7): billing_email is the recovery address and
# the identity an invite attaches to, yet nothing kept it unique — a second
# account could claim a colleague's address and win `find_by` lookups. Lower-
# cased in place, then unique per address (case-insensitive). The full
# verification flow is deferred; this makes the lookups deterministic.
class AddUniqueBillingEmailToUsers < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE users SET billing_email = LOWER(TRIM(billing_email)) WHERE billing_email IS NOT NULL AND billing_email <> LOWER(TRIM(billing_email))"
    execute "UPDATE users SET billing_email = NULL WHERE billing_email = ''"
    add_index :users, "LOWER(billing_email)", unique: true, where: "billing_email IS NOT NULL",
              name: "index_users_on_lower_billing_email", if_not_exists: true
  end

  def down
    remove_index :users, name: "index_users_on_lower_billing_email", if_exists: true
  end
end
