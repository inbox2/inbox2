# Out-of-office auto-replies (docs/Calendar.md).
#
# `out_of_office_replies` is the loop-prevention ledger: one row per
# (person, sender, absence), so a correspondent is answered once per absence and
# never again. The UNIQUE index is the actual guard — a SELECT-then-INSERT check
# cannot stop two concurrent inbound deliveries of the same mail from both
# deciding to reply, and a mail loop is the one failure mode here that gets
# expensive fast.
#
# `messages.auto_submitted` carries the RFC 3834 header value onto the wire.
# Delivery is asynchronous (and retried), so the fact that a message is an
# auto-reply has to survive on the row rather than in the sending call.
#
# Its own file so production actually migrates: prod already recorded
# 20260522000001, so folding this into the initial schema would never reach it.
# Both are ALSO in the initial schema so a fresh install still gets everything
# from one file; `if_not_exists` makes this a no-op there.
class AddOutOfOfficeAutoReply < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :auto_submitted, :string, if_not_exists: true

    create_table :out_of_office_replies, if_not_exists: true do |t|
      t.bigint :user_id, null: false
      t.bigint :organization_id, null: false
      t.string :sender_address, null: false
      # Which absence this reply belongs to. A new period means a genuinely new
      # absence, so everyone becomes answerable again.
      t.datetime :period_start, null: false
      t.timestamps
      t.index %i[user_id sender_address period_start],
              unique: true, name: "index_ooo_replies_on_user_sender_period"
      t.index :organization_id, name: "index_ooo_replies_on_organization_id"
    end

    add_foreign_key :out_of_office_replies, :users, if_not_exists: true
    add_foreign_key :out_of_office_replies, :organizations, if_not_exists: true
  end
end
