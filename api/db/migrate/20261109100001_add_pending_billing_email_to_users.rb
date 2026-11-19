# Contact-address confirmation (docs/TODO.md 48.21): a new address waits here until
# its owner clicks the mailed link; users.billing_email only ever holds a confirmed one.
class AddPendingBillingEmailToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :pending_billing_email, :string, if_not_exists: true
    add_column :users, :billing_email_token_digest, :string, if_not_exists: true
    add_column :users, :billing_email_token_sent_at, :datetime, if_not_exists: true
    add_index :users, :billing_email_token_digest, unique: true, where: "billing_email_token_digest IS NOT NULL",
                                                   if_not_exists: true
  end
end
