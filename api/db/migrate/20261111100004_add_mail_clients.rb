# Mail clients: IMAP and SMTP submission for hosted mail (docs/Mail-Clients.md).
# Off per organization by default.
class AddMailClients < ActiveRecord::Migration[8.1]
  def up
    add_column :organizations, :mail_clients_enabled, :boolean, null: false, default: false, if_not_exists: true
    # The header block of a message as it arrived (or as a mail client
    # submitted it), so the message can be rebuilt with its own headers.
    add_column :messages, :raw_headers, :text, if_not_exists: true

    create_table :mail_client_passwords, if_not_exists: true do |t|
      t.string :key, null: false, index: { unique: true }
      t.references :membership, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :prefix, null: false, index: { unique: true }
      t.string :token_digest, null: false
      t.datetime :last_used_at
      t.timestamps
    end

    create_table :imap_folders, if_not_exists: true do |t|
      t.references :membership, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :name, null: false
      t.bigint :uidvalidity, null: false
      t.bigint :uidnext, null: false, default: 1
      t.index %i[membership_id name], unique: true
    end

    # Where one message sits in one person's IMAP view. A message is in exactly
    # one folder per person, so its flags survive a move.
    create_table :imap_messages, if_not_exists: true do |t|
      t.references :membership, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :message, null: false, foreign_key: { on_delete: :cascade }
      t.string :folder, null: false
      t.bigint :uid, null: false
      t.string :flags, array: true, null: false, default: []
      t.boolean :expunged, null: false, default: false
      t.integer :size
      t.index %i[membership_id message_id], unique: true
      t.index %i[membership_id folder uid], unique: true
    end
  end

  def down
    %i[imap_messages imap_folders mail_client_passwords].each { |t| drop_table t, if_exists: true }
    remove_column :messages, :raw_headers, if_exists: true
    remove_column :organizations, :mail_clients_enabled, if_exists: true
  end
end
