# Whose personal mailbox a thread belongs to, kept as a member id because a
# sealed (E2EE) thread stores no addresses to check (Conversation.visible_to).
class AddPersonalMembershipIdToConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :personal_membership_id, :bigint, if_not_exists: true
    add_index :conversations, :personal_membership_id, where: "(personal_membership_id IS NOT NULL)", if_not_exists: true
    # A member who leaves hands their threads back to the org (offboard archive).
    add_foreign_key :conversations, :memberships, column: :personal_membership_id, on_delete: :nullify, if_not_exists: true
  end
end
