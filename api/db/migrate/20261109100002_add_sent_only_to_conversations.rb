# A thread nothing has come in on yet: it stays open (Lore's Waiting list reads
# open threads) but the Inbox skips it. See Conversation#refresh_sent_only!.
class AddSentOnlyToConversations < ActiveRecord::Migration[8.1]
  def up
    add_column :conversations, :sent_only, :boolean, default: false, null: false, if_not_exists: true
    execute <<~SQL
      UPDATE conversations c SET sent_only = true, read = true
       WHERE EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = c.id AND NOT m.is_draft)
         AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = c.id AND m.is_inbound)
    SQL
  end

  def down
    remove_column :conversations, :sent_only
  end
end
