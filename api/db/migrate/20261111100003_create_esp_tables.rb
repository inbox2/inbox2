# The ESP: mail sent by an application through the API (docs/ESP.md). Its own
# send log, so API mail never enters conversations or the sync feed.
class CreateEspTables < ActiveRecord::Migration[8.1]
  def up
    create_table :esp_domains, if_not_exists: true do |t|
      t.string :key, null: false, index: { unique: true }
      t.references :organization, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :status, null: false, default: "pending_dns"
      t.jsonb :dns_checks, null: false, default: {}
      t.datetime :dns_checked_at
      t.timestamps
      t.index "lower(name)", unique: true, name: "index_esp_domains_on_lower_name"
    end

    create_table :esp_keys, if_not_exists: true do |t|
      t.string :key, null: false, index: { unique: true }
      t.references :organization, null: false, foreign_key: { on_delete: :cascade }
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :name, null: false
      t.string :prefix, null: false, index: { unique: true }
      t.string :token_digest, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps
    end

    create_table :esp_messages, if_not_exists: true do |t|
      t.string :key, null: false, index: { unique: true }
      t.references :organization, null: false, foreign_key: { on_delete: :cascade }
      t.references :esp_key, null: false, foreign_key: true
      t.string :from_address, null: false
      t.text :to_address, null: false
      t.text :cc_address
      t.text :bcc_address
      t.string :reply_to
      t.string :subject
      t.string :tag
      t.jsonb :metadata, null: false, default: {}
      t.string :message_id_header, null: false
      t.string :idempotency_key
      t.binary :raw_mime
      t.integer :size_bytes, null: false, default: 0
      t.timestamps
      t.index %i[organization_id created_at]
      t.index %i[organization_id idempotency_key], unique: true, where: "idempotency_key IS NOT NULL",
        name: "index_esp_messages_on_org_and_idempotency_key"
      t.index :message_id_header
    end

    create_table :esp_deliveries, if_not_exists: true do |t|
      t.string :key, null: false, index: { unique: true }
      t.references :organization, null: false, foreign_key: { on_delete: :cascade }
      t.references :esp_message, null: false, foreign_key: { on_delete: :cascade }
      t.string :recipient, null: false
      t.string :status, null: false, default: "queued"
      t.string :bounce_token, null: false, index: { unique: true }
      t.integer :attempt_count, null: false, default: 0
      t.string :smtp_code
      t.text :response
      t.string :mx_host
      t.datetime :published_at
      t.datetime :delivered_at
      t.datetime :failed_at
      t.timestamps
      t.index %i[organization_id created_at]
      t.index %i[organization_id recipient]
    end

    create_table :esp_events, if_not_exists: true do |t|
      t.string :key, null: false, index: { unique: true }
      t.references :organization, null: false, foreign_key: { on_delete: :cascade }
      t.references :esp_message, null: false, foreign_key: { on_delete: :cascade }
      t.references :esp_delivery, null: false, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false
      t.jsonb :detail, null: false, default: {}
      t.datetime :created_at, null: false
    end
  end

  def down
    %i[esp_events esp_deliveries esp_messages esp_keys esp_domains].each { |t| drop_table t, if_exists: true }
  end
end
