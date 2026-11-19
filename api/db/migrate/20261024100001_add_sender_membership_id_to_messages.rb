# Who sent an outbound message (undo-send is the sender's alone; a sealed
# message has no plaintext From to authorize against).
class AddSenderMembershipIdToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :sender_membership_id, :bigint, if_not_exists: true
  end
end
