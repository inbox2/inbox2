# Mail import (docs/plans/mail-import.md, 2026-10-07): an admin moves a domain's
# mailboxes from Google Workspace or Microsoft 365 onto MX. Imported history is
# private to the person it came from: conversations.private keeps it out of the
# domain's inbox (Conversation.visible_to), and a ConversationAccess grants the owner.
# One mail_imports row per source mailbox, re-run for the catch-up after the
# MX flip; mail_import_threads maps a source thread id to the conversation it became.
class CreateMailImports < ActiveRecord::Migration[8.1]
  def up
    add_column :conversations, :private, :boolean, default: false, null: false, if_not_exists: true

    create_table :mail_imports, if_not_exists: true do |t|
      t.string :key, null: false
      t.bigint :organization_id, null: false
      t.bigint :membership_id, null: false
      t.bigint :owner_membership_id, null: false
      t.bigint :domain_id, null: false
      t.bigint :connection_id
      t.string :provider, null: false
      t.string :source_email, null: false
      t.string :state, null: false
      t.string :pause_reason
      t.text :error
      t.text :cursor
      t.jsonb :counts, default: {}, null: false
      t.jsonb :report, default: {}, null: false
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
      t.index :key, unique: true
      t.index %i[organization_id provider source_email], unique: true, name: "index_mail_imports_on_org_provider_source"
      t.index :owner_membership_id
    end
    add_foreign_key :mail_imports, :organizations unless foreign_key_exists?(:mail_imports, :organizations)
    unless foreign_key_exists?(:mail_imports, :memberships, column: :membership_id)
      add_foreign_key :mail_imports, :memberships, on_delete: :cascade
    end
    unless foreign_key_exists?(:mail_imports, :memberships, column: :owner_membership_id)
      add_foreign_key :mail_imports, :memberships, column: :owner_membership_id, on_delete: :cascade
    end
    add_foreign_key :mail_imports, :domains, on_delete: :cascade unless foreign_key_exists?(:mail_imports, :domains)
    unless foreign_key_exists?(:mail_imports, :disk_import_connections)
      add_foreign_key :mail_imports, :disk_import_connections, column: :connection_id, on_delete: :nullify
    end

    create_table :mail_import_threads, if_not_exists: true do |t|
      t.bigint :mail_import_id, null: false
      t.string :source_thread_id, null: false
      t.bigint :conversation_id, null: false
      t.timestamps
      t.index %i[mail_import_id source_thread_id], unique: true, name: "index_mail_import_threads_on_import_and_source"
      t.index :conversation_id
    end
    unless foreign_key_exists?(:mail_import_threads, :mail_imports)
      add_foreign_key :mail_import_threads, :mail_imports, on_delete: :cascade
    end
    unless foreign_key_exists?(:mail_import_threads, :conversations)
      add_foreign_key :mail_import_threads, :conversations, on_delete: :cascade
    end
  end

  def down
    drop_table :mail_import_threads, if_exists: true
    drop_table :mail_imports, if_exists: true
    remove_column :conversations, :private, if_exists: true
  end
end
