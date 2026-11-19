# Separate private copies (docs/plans/mail-import.md D9/D10, 2026-10-07): a
# private conversation and its messages belong to one member, so two colleagues
# who both had a message each keep their own copy. A Message-ID (and its sealed
# HMAC) is unique per (org, owner) instead of per org; shared mail has no owner.
class AddOwnerToPrivateMail < ActiveRecord::Migration[8.1]
  def up
    add_column :conversations, :owner_membership_id, :bigint, if_not_exists: true
    add_column :messages, :owner_membership_id, :bigint, if_not_exists: true
    add_index :conversations, :owner_membership_id, where: "owner_membership_id IS NOT NULL", if_not_exists: true
    unless foreign_key_exists?(:conversations, :memberships, column: :owner_membership_id)
      add_foreign_key :conversations, :memberships, column: :owner_membership_id, on_delete: :cascade
    end
    unless foreign_key_exists?(:messages, :memberships, column: :owner_membership_id)
      add_foreign_key :messages, :memberships, column: :owner_membership_id, on_delete: :cascade
    end

    add_index :messages, "organization_id, message_id_header, COALESCE(owner_membership_id, (0)::bigint)",
              name: "index_messages_on_org_message_id_owner", unique: true, where: "(message_id_header IS NOT NULL)",
              if_not_exists: true
    add_index :messages, "organization_id, msgid_hmac, COALESCE(owner_membership_id, (0)::bigint)",
              name: "index_messages_on_org_msgid_hmac_owner", unique: true, where: "(msgid_hmac IS NOT NULL)",
              if_not_exists: true
    remove_index :messages, name: "index_messages_on_org_id_and_message_id_header", if_exists: true
    remove_index :messages, name: "index_messages_on_org_id_and_msgid_hmac", if_exists: true
  end

  def down
    add_index :messages, %i[organization_id message_id_header], name: "index_messages_on_org_id_and_message_id_header",
                                                                unique: true, where: "(message_id_header IS NOT NULL)", if_not_exists: true
    add_index :messages, %i[organization_id msgid_hmac], name: "index_messages_on_org_id_and_msgid_hmac",
                                                         unique: true, where: "(msgid_hmac IS NOT NULL)", if_not_exists: true
    remove_index :messages, name: "index_messages_on_org_message_id_owner", if_exists: true
    remove_index :messages, name: "index_messages_on_org_msgid_hmac_owner", if_exists: true
    remove_column :messages, :owner_membership_id, if_exists: true
    remove_column :conversations, :owner_membership_id, if_exists: true
  end
end
