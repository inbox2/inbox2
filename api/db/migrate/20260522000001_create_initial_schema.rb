# The complete inbox2 schema, in one migration.
#
# Flattened on 2026-08-05 for the open-source baseline: a fresh install runs
# this file and nothing else — no follow-up migrations, no extensions to
# enable by hand. Generated from db/schema.rb, which stays the source of
# truth; the two are verified equivalent by loading each into a scratch
# database and diffing pg_dump output.
#
# The version is deliberately unchanged from the migration this replaces, so
# the existing production database (which already recorded it) sees nothing
# pending. Keep folding new schema changes in here until launch.
class CreateInitialSchema < ActiveRecord::Migration[8.1]
  def change
    # These are extensions that must be enabled in order to support this database
    enable_extension "pg_catalog.plpgsql"
    enable_extension "pg_trgm"

    create_table "activity_events", force: :cascade do |t|
      t.string "action", null: false
      t.bigint "conversation_id", null: false
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.bigint "membership_id"
      t.jsonb "metadata", default: {}
      t.bigint "organization_id", null: false
      t.datetime "updated_at", null: false
      t.index ["conversation_id", "created_at"], name: "index_activity_events_on_conversation_id_and_created_at"
      t.index ["key"], name: "index_activity_events_on_key", unique: true
      t.index ["organization_id", "membership_id", "created_at"], name: "index_activity_events_on_org_membership_created"
    end

    create_table "admin_credentials", force: :cascade do |t|
      t.string "cert_fingerprint", null: false
      t.datetime "created_at", null: false
      t.string "email"
      t.string "key", null: false
      t.string "label", null: false
      t.datetime "last_used_at"
      t.string "last_used_ip"
      t.datetime "revoked_at"
      t.datetime "updated_at", null: false
      t.index ["cert_fingerprint"], name: "index_admin_credentials_on_cert_fingerprint", unique: true
      t.index ["key"], name: "index_admin_credentials_on_key", unique: true
    end

    create_table "agencies", force: :cascade do |t|
      t.string "billing_email"
      t.datetime "created_at", null: false
      t.integer "discount_percent", default: 0
      t.string "key", null: false
      t.string "name", null: false
      t.bigint "owner_id", null: false
      t.string "status", default: "active", null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_agencies_on_key", unique: true
      t.index ["owner_id"], name: "index_agencies_on_owner_id"
    end

    create_table "agent_run_logs", force: :cascade do |t|
      t.string "action", null: false
      t.bigint "agent_id", null: false
      t.bigint "conversation_id"
      t.integer "cost_cents", default: 0
      t.datetime "created_at", null: false
      t.integer "duration_ms"
      t.text "error_message"
      t.string "key", null: false
      t.jsonb "metadata", default: {}
      t.string "status", null: false
      t.datetime "updated_at", null: false
      t.index ["agent_id", "created_at"], name: "index_agent_run_logs_on_agent_id_and_created_at"
      t.index ["agent_id"], name: "index_agent_run_logs_on_agent_id"
      t.index ["conversation_id"], name: "index_agent_run_logs_on_conversation_id"
      t.index ["key"], name: "index_agent_run_logs_on_key", unique: true
    end

    create_table "agents", force: :cascade do |t|
      t.string "api_credential_digest"
      t.boolean "approval_required", default: false, null: false
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.bigint "membership_id", null: false
      t.string "name", null: false
      t.bigint "organization_id", null: false
      t.jsonb "permissions", default: [], null: false
      t.integer "rate_limit", default: 100
      t.integer "spend_limit_cents", default: 0
      t.string "status", default: "active", null: false
      t.bigint "supervisor_membership_id"
      t.integer "total_runs", default: 0
      t.integer "total_spend_cents", default: 0
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_agents_on_key", unique: true
      t.index ["organization_id"], name: "index_agents_on_organization_id"
    end

    # The now() defaults are not Rails' usual style — Rails sets timestamps
    # itself — but this table was created on production by hand rather than by
    # a migration, and carried them. Reproduced here so a fresh install and
    # production end up with the same table rather than nearly the same one.
    create_table "ai_triage_usages", force: :cascade do |t|
      t.datetime "created_at", default: -> { "now()" }, null: false
      t.bigint "organization_id", null: false
      t.string "period", null: false
      t.bigint "scope_id", null: false
      t.string "scope_type", null: false
      t.integer "throttled_count", default: 0, null: false
      t.integer "triaged_count", default: 0, null: false
      t.datetime "updated_at", default: -> { "now()" }, null: false
      t.index ["organization_id", "scope_type", "scope_id", "period"], name: "index_ai_triage_usages_unique", unique: true
    end

    create_table "api_keys", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.string "device_platform"
      t.datetime "expires_at"
      t.string "key", null: false
      t.datetime "last_used_at"
      t.string "name", null: false
      t.string "prefix", null: false
      t.jsonb "scopes", default: []
      t.string "token_digest", null: false
      t.datetime "updated_at", null: false
      t.bigint "user_id", null: false
      t.index ["key"], name: "index_api_keys_on_key", unique: true
      t.index ["prefix"], name: "index_api_keys_on_prefix", unique: true
      t.index ["user_id"], name: "index_api_keys_on_user_id"
    end

    create_table "attachments", force: :cascade do |t|
      t.text "content_nonce"
      t.text "content_text"
      t.string "content_type"
      t.datetime "created_at", null: false
      t.string "filename"
      t.text "filename_nonce"
      t.string "key", null: false
      t.bigint "message_id", null: false
      t.bigint "organization_id", null: false
      t.text "sealed_filename"
      t.tsvector "search_vector"
      t.integer "size_bytes", default: 0
      t.string "storage_key"
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_attachments_on_key", unique: true
      t.index ["message_id"], name: "index_attachments_on_message_id"
      t.index ["organization_id"], name: "index_attachments_on_organization_id"
      t.index ["search_vector"], name: "index_attachments_on_search_vector", using: :gin
    end

    create_table "audit_logs", force: :cascade do |t|
      t.string "action", null: false
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.bigint "membership_id"
      t.jsonb "metadata", default: {}
      t.bigint "organization_id", null: false
      t.string "resource_id"
      t.string "resource_type"
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_audit_logs_on_key", unique: true
      t.index ["organization_id", "created_at"], name: "index_audit_logs_on_organization_id_and_created_at"
    end

    create_table "blocked_times", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.datetime "end_at", null: false
      t.string "key", null: false
      t.bigint "membership_id", null: false
      t.bigint "organization_id", null: false
      t.datetime "start_at", null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_blocked_times_on_key", unique: true
      t.index ["organization_id", "membership_id", "start_at"], name: "index_blocked_times_on_org_membership_start"
    end

    create_table "calendar_attendees", force: :cascade do |t|
      t.bigint "calendar_event_id", null: false
      t.text "comment"
      t.datetime "created_at", null: false
      t.string "email", null: false
      t.boolean "is_optional", default: false, null: false
      t.boolean "is_organizer", default: false, null: false
      t.string "key", null: false
      t.string "name"
      t.datetime "proposed_end"
      t.datetime "proposed_start"
      t.datetime "responded_at"
      t.string "response_status", default: "needs_action", null: false
      t.datetime "updated_at", null: false
      t.index ["calendar_event_id", "email"], name: "index_calendar_attendees_on_event_and_email", unique: true
      t.index ["calendar_event_id"], name: "index_calendar_attendees_on_calendar_event_id"
      t.index ["email"], name: "index_calendar_attendees_on_email"
      t.index ["key"], name: "index_calendar_attendees_on_key", unique: true
      t.index "lower((email)::text)", name: "index_calendar_attendees_on_lower_email"
    end

    create_table "calendar_events", force: :cascade do |t|
      t.boolean "all_day", default: false, null: false
      t.bigint "calendar_id", null: false
      t.string "conversation_key"
      t.datetime "created_at", null: false
      t.bigint "created_by_membership_id"
      t.text "description"
      t.datetime "end_at", null: false
      t.string "ical_uid"
      t.string "key", null: false
      t.string "location"
      t.jsonb "metadata", default: {}
      t.bigint "organization_id", null: false
      t.string "organizer_email"
      t.string "organizer_name"
      t.datetime "original_start_at"
      t.string "recurrence_rule"
      t.string "recurring_event_key"
      t.integer "sequence", default: 0, null: false
      t.datetime "start_at", null: false
      t.string "status", default: "confirmed", null: false
      t.string "timezone", default: "UTC"
      t.string "title", null: false
      t.datetime "updated_at", null: false
      t.string "visibility", default: "default", null: false
      t.index ["calendar_id", "start_at", "end_at"], name: "index_calendar_events_on_calendar_and_range"
      t.index ["conversation_key"], name: "index_calendar_events_on_conversation_key"
      t.index ["ical_uid"], name: "index_calendar_events_on_ical_uid"
      t.index ["key"], name: "index_calendar_events_on_key", unique: true
      t.index ["organization_id", "start_at", "end_at"], name: "index_calendar_events_on_org_and_range"
      t.index ["recurring_event_key"], name: "index_calendar_events_on_recurring_event_key"
    end

    create_table "calendar_reminders", force: :cascade do |t|
      t.bigint "calendar_event_id", null: false
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.string "method", default: "popup", null: false
      t.integer "minutes_before", null: false
      t.datetime "updated_at", null: false
      t.index ["calendar_event_id"], name: "index_calendar_reminders_on_calendar_event_id"
      t.index ["key"], name: "index_calendar_reminders_on_key", unique: true
    end

    create_table "calendars", force: :cascade do |t|
      t.string "color", default: "#3B82F6"
      t.datetime "created_at", null: false
      t.text "description"
      t.boolean "is_primary", default: false, null: false
      t.boolean "is_visible", default: true, null: false
      t.string "key", null: false
      t.datetime "last_synced_at"
      t.bigint "membership_id"
      t.string "name", null: false
      t.bigint "organization_id", null: false
      t.string "source", default: "inbox2", null: false
      t.string "status", default: "active", null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_calendars_on_key", unique: true
      t.index ["organization_id", "membership_id"], name: "index_calendars_on_organization_id_and_membership_id"
      t.index ["organization_id"], name: "index_calendars_on_organization_id"
    end

    create_table "channel_tracking_settings", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.string "email_address", null: false
      t.boolean "open_tracking_enabled", default: false, null: false
      t.string "track_domain"
      t.datetime "updated_at", null: false
      t.bigint "user_id", null: false
      t.index ["user_id", "email_address"], name: "index_channel_tracking_settings_on_user_id_and_email_address", unique: true
      t.index ["user_id"], name: "index_channel_tracking_settings_on_user_id"
    end

    create_table "channel_push_subscriptions", force: :cascade do |t|
      t.string "client_state"
      t.datetime "created_at", null: false
      t.datetime "expires_at"
      t.string "external_email", null: false
      t.string "key", null: false
      t.datetime "last_notification_at"
      t.datetime "last_seen_at"
      t.datetime "lease_expires_at"
      t.string "provider", null: false
      t.string "provider_subscription_id"
      t.string "status", default: "active", null: false
      t.datetime "updated_at", null: false
      t.bigint "user_id", null: false
      t.index ["external_email"], name: "index_channel_push_subscriptions_on_external_email"
      t.index ["key"], name: "index_channel_push_subscriptions_on_key", unique: true
      t.index ["provider_subscription_id"], name: "index_channel_push_subscriptions_on_provider_sub_id"
      t.index ["user_id", "provider", "external_email"], name: "index_channel_push_subscriptions_on_user_provider_email", unique: true
      t.index ["user_id"], name: "index_channel_push_subscriptions_on_user_id"
    end

    create_table "conferencing_connections", force: :cascade do |t|
      t.string "account_email"
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.bigint "membership_id", null: false
      t.string "provider", null: false
      t.text "refresh_token", null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_conferencing_connections_on_key", unique: true
      t.index ["membership_id", "provider"], name: "index_conferencing_connections_on_membership_id_and_provider", unique: true
    end

    create_table "contacts", force: :cascade do |t|
      t.string "company"
      t.datetime "created_at", null: false
      t.string "email", null: false
      t.string "key", null: false
      t.string "name"
      t.text "notes"
      t.bigint "organization_id", null: false
      t.string "phone"
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_contacts_on_key", unique: true
      t.index ["organization_id", "email"], name: "index_contacts_on_organization_id_and_email", unique: true
    end

    create_table "conversation_accesses", force: :cascade do |t|
      t.bigint "conversation_id", null: false
      t.datetime "created_at", null: false
      t.bigint "membership_id", null: false
      t.datetime "updated_at", null: false
      t.index ["conversation_id", "membership_id"], name: "idx_conv_access_unique", unique: true
      t.index ["membership_id"], name: "index_conversation_accesses_on_membership_id"
    end

    create_table "conversation_assignees", force: :cascade do |t|
      t.bigint "conversation_id", null: false
      t.datetime "created_at", null: false
      t.bigint "membership_id", null: false
      t.datetime "updated_at", null: false
      t.index ["conversation_id", "membership_id"], name: "idx_conv_assignees_unique", unique: true
      t.index ["membership_id"], name: "index_conversation_assignees_on_membership_id"
    end

    create_table "conversation_tags", force: :cascade do |t|
      t.bigint "conversation_id", null: false
      t.datetime "created_at", null: false
      t.bigint "tag_id", null: false
      t.datetime "updated_at", null: false
      t.index ["conversation_id", "tag_id"], name: "index_conversation_tags_on_conversation_id_and_tag_id", unique: true
      t.index ["tag_id"], name: "index_conversation_tags_on_tag_id"
    end

    create_table "conversations", force: :cascade do |t|
      t.string "ai_summary_short"
      t.bigint "change_seq"
      t.bigint "change_xid"
      t.datetime "created_at", null: false
      t.bigint "domain_id"
      t.string "from_address"
      t.boolean "is_task", default: false, null: false
      t.string "key", null: false
      t.integer "messages_count", default: 0, null: false
      t.bigint "next_action_amount_cents"
      t.string "next_action_currency"
      t.date "next_action_due_on"
      t.string "next_action_title", limit: 80
      t.bigint "organization_id", null: false
      t.bigint "owner_membership_id"
      t.bigint "personal_membership_id"
      t.boolean "private", default: false, null: false
      t.boolean "read", default: false, null: false
      t.tsvector "search_vector"
      t.boolean "sent_only", default: false, null: false
      t.string "snippet"
      t.datetime "snoozed_until"
      t.bigint "space_id"
      t.string "status", default: "open", null: false
      t.string "subject"
      t.string "subject_hmac"
      t.datetime "task_due_date"
      t.string "to_address"
      t.string "triage_label"
      t.float "triage_priority"
      t.string "triage_source"
      t.datetime "updated_at", null: false
      t.index ["organization_id", "domain_id", "space_id"], name: "index_conversations_on_open_unread", where: "(((status)::text = 'open'::text) AND (read = false))"
      t.index "((((COALESCE(subject, ''::character varying))::text || ' '::text) || (COALESCE(from_address, ''::character varying))::text)) gin_trgm_ops", name: "index_conversations_on_search_terms_trgm", using: :gin
      t.index ["domain_id"], name: "index_conversations_on_domain_id"
      t.index ["key"], name: "index_conversations_on_key", unique: true
      t.index ["organization_id", "change_xid", "change_seq"], name: "index_conversations_on_sync_cursor", where: "(change_seq IS NOT NULL)"
      t.index ["organization_id", "domain_id", "status", "updated_at"], name: "index_conversations_on_org_domain_status_updated"
      t.index ["organization_id", "from_address"], name: "index_conversations_on_org_id_and_from_address"
      t.index ["organization_id", "space_id"], name: "index_conversations_on_organization_id_and_space_id"
      t.index ["organization_id", "status", "updated_at"], name: "index_conversations_on_org_id_status_updated_at"
      t.index ["organization_id", "status"], name: "index_conversations_on_organization_id_and_status"
      t.index ["organization_id", "subject"], name: "index_conversations_on_org_id_and_subject"
      t.index ["organization_id", "subject_hmac"], name: "index_conversations_on_org_id_and_subject_hmac"
      t.index ["organization_id", "to_address"], name: "index_conversations_on_org_id_and_to_address"
      t.index ["organization_id", "updated_at"], name: "index_conversations_on_organization_id_and_updated_at"
      t.index ["organization_id"], name: "index_conversations_on_organization_id"
      t.index ["owner_membership_id"], name: "index_conversations_on_owner_membership_id", where: "(owner_membership_id IS NOT NULL)"
      t.index ["personal_membership_id"], name: "index_conversations_on_personal_membership_id", where: "(personal_membership_id IS NOT NULL)"
      t.index ["search_vector"], name: "index_conversations_on_search_vector", using: :gin
      t.index ["space_id"], name: "index_conversations_on_space_id"
    end

    create_table "credential_vaults", force: :cascade do |t|
      t.jsonb "argon_params", default: {}, null: false
      t.text "argon_salt"
      t.datetime "created_at", null: false
      t.text "device_wrapped_dek"
      t.string "key", null: false
      t.text "passphrase_wrapped_dek"
      t.datetime "updated_at", null: false
      t.bigint "user_id", null: false
      t.index ["key"], name: "index_credential_vaults_on_key", unique: true
      t.index ["user_id"], name: "index_credential_vaults_on_user_id", unique: true
    end

    create_table "custom_roles", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.string "name", null: false
      t.bigint "organization_id", null: false
      t.jsonb "permissions", default: [], null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_custom_roles_on_key", unique: true
      t.index ["organization_id"], name: "index_custom_roles_on_organization_id"
    end

    create_table "custom_statuses", force: :cascade do |t|
      t.string "color", default: "#6B7280"
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.string "name", null: false
      t.bigint "organization_id", null: false
      t.integer "position", default: 0, null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_custom_statuses_on_key", unique: true
      t.index ["organization_id", "name"], name: "index_custom_statuses_on_organization_id_and_name", unique: true
    end

    create_table "data_exports", force: :cascade do |t|
      t.bigint "byte_size"
      t.jsonb "counts", default: {}, null: false
      t.datetime "created_at", null: false
      t.text "error"
      t.datetime "expires_at"
      t.string "key", null: false
      t.bigint "organization_id", null: false
      t.bigint "requested_by_membership_id"
      t.string "status", default: "queued", null: false
      t.string "storage_key"
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_data_exports_on_key", unique: true
      t.index ["organization_id", "created_at"], name: "index_data_exports_on_org_and_created"
      t.index ["organization_id"], name: "index_data_exports_one_active_per_org", unique: true, where: "((status)::text = ANY ((ARRAY['queued'::character varying, 'running'::character varying])::text[]))"
    end

    create_table "delivery_attempts", force: :cascade do |t|
      t.integer "attempt_number", null: false
      t.datetime "created_at", null: false
      t.bigint "delivery_channel_id"
      t.bigint "delivery_status_id", null: false
      t.string "enhanced_status_code"
      t.string "key", null: false
      t.text "response_message"
      t.string "result", null: false
      t.string "smtp_response_code"
      t.datetime "updated_at", null: false
      t.index ["delivery_status_id"], name: "index_delivery_attempts_on_delivery_status_id"
      t.index ["key"], name: "index_delivery_attempts_on_key", unique: true
    end

    create_table "delivery_channels", force: :cascade do |t|
      t.jsonb "config", default: {}, null: false
      t.datetime "created_at", null: false
      t.boolean "is_default", default: false, null: false
      t.string "key", null: false
      t.string "kind", default: "builtin", null: false
      t.string "name", null: false
      t.bigint "organization_id", null: false
      t.string "status", default: "active", null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_delivery_channels_on_key", unique: true
      t.index ["organization_id"], name: "index_delivery_channels_on_organization_id"
    end

    create_table "delivery_statuses", force: :cascade do |t|
      t.integer "attempt_count", default: 0, null: false
      t.string "bounce_type"
      t.datetime "created_at", null: false
      t.datetime "delivered_at"
      t.bigint "delivery_channel_id"
      t.string "destination"
      t.string "dsn_code"
      t.text "dsn_diagnostic"
      t.datetime "failed_at"
      t.string "key", null: false
      t.bigint "message_id", null: false
      t.datetime "published_at"
      t.text "recipients"
      t.string "status", default: "queued", null: false
      t.datetime "updated_at", null: false
      t.index ["delivery_channel_id", "status"], name: "index_delivery_statuses_on_channel_and_status"
      t.index ["created_at"], name: "index_delivery_statuses_on_created_at"
      t.index ["key"], name: "index_delivery_statuses_on_key", unique: true
      t.index ["message_id"], name: "index_delivery_statuses_on_message_id"
    end

    create_table "device_link_requests", force: :cascade do |t|
      t.string "code_challenge", null: false
      t.string "code_challenge_method", default: "S256", null: false
      t.string "code_digest", null: false
      t.datetime "created_at", null: false
      t.string "device_name", null: false
      t.datetime "expires_at", null: false
      t.string "key", null: false
      t.string "platform", null: false
      t.string "prefix", null: false
      t.string "redirect_uri", null: false
      t.string "status", default: "pending", null: false
      t.datetime "updated_at", null: false
      t.bigint "user_id", null: false
      t.index ["key"], name: "index_device_link_requests_on_key", unique: true
      t.index ["prefix"], name: "index_device_link_requests_on_prefix", unique: true
      t.index ["user_id"], name: "index_device_link_requests_on_user_id"
    end

    create_table "disk_agent_grants", force: :cascade do |t|
      t.bigint "agent_id", null: false
      t.datetime "created_at", null: false
      t.bigint "granted_by_membership_id"
      t.bigint "node_id", null: false
      t.bigint "organization_id", null: false
      t.string "role", null: false
      t.datetime "updated_at", null: false
      t.index ["agent_id", "node_id"], name: "index_disk_agent_grants_on_agent_id_and_node_id", unique: true
      t.index ["node_id"], name: "index_disk_agent_grants_on_node_id"
    end

    create_table "disk_events", force: :cascade do |t|
      t.string "action", null: false
      t.bigint "actor_agent_id"
      t.bigint "actor_membership_id"
      t.datetime "created_at", null: false
      t.jsonb "detail", default: {}, null: false
      t.string "key", null: false
      t.bigint "link_id"
      t.bigint "node_id"
      t.bigint "organization_id", null: false
      t.bigint "share_id"
      t.datetime "updated_at", null: false
      t.index ["actor_agent_id"], name: "index_disk_events_on_actor_agent_id"
      t.index ["key"], name: "index_disk_events_on_key", unique: true
      t.index ["link_id"], name: "index_disk_events_on_link_id"
      t.index ["node_id", "created_at"], name: "index_disk_events_on_node_id_and_created_at"
      t.index ["organization_id"], name: "index_disk_events_on_organization_id"
      t.index ["share_id", "created_at"], name: "index_disk_events_on_share_id_and_created_at"
    end

    create_table "disk_grants", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.bigint "granted_by_membership_id"
      t.string "key", null: false
      t.bigint "membership_id", null: false
      t.bigint "node_id", null: false
      t.bigint "organization_id", null: false
      t.string "role", null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_disk_grants_on_key", unique: true
      t.index ["membership_id"], name: "index_disk_grants_on_membership_id"
      t.index ["node_id", "membership_id"], name: "index_disk_grants_on_node_id_and_membership_id", unique: true
    end

    create_table "disk_import_connections", force: :cascade do |t|
      t.datetime "access_expires_at"
      t.text "access_token"
      t.string "account_email"
      t.datetime "created_at", null: false
      t.bigint "membership_id", null: false
      t.bigint "organization_id", null: false
      t.string "provider", null: false
      t.string "reach", null: false
      t.text "refresh_token"
      t.string "tenant"
      t.datetime "throttled_until"
      t.datetime "updated_at", null: false
      t.index ["membership_id", "provider", "reach"], name: "index_disk_import_connections_unique", unique: true
      t.index ["provider", "tenant"], name: "index_disk_import_connections_on_provider_and_tenant"
    end

    create_table "disk_import_items", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.jsonb "detail", default: {}, null: false
      t.bigint "import_id", null: false
      t.string "name"
      t.bigint "node_id"
      t.bigint "organization_id", null: false
      t.string "provider", null: false
      t.string "reason"
      t.string "source_id", null: false
      t.datetime "source_modified_at"
      t.string "status", null: false
      t.bigint "target_node_id", null: false
      t.datetime "updated_at", null: false
      t.index ["import_id", "status"], name: "index_disk_import_items_on_import_id_and_status"
      t.index ["organization_id", "provider", "target_node_id", "source_id"], name: "index_disk_import_items_on_source", unique: true
    end

    create_table "disk_imports", force: :cascade do |t|
      t.bigint "connection_id"
      t.jsonb "counts", default: {}, null: false
      t.datetime "created_at", null: false
      t.text "cursor"
      t.text "error"
      t.datetime "finished_at"
      t.string "key", null: false
      t.bigint "membership_id", null: false
      t.bigint "organization_id", null: false
      t.bigint "owner_membership_id"
      t.string "pause_reason"
      t.string "provider", null: false
      t.jsonb "report", default: {}, null: false
      t.bigint "share_id"
      t.string "source_email"
      t.string "space_id"
      t.string "space_kind", null: false
      t.string "space_name"
      t.datetime "started_at"
      t.string "state", null: false
      t.bigint "target_node_id"
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_disk_imports_on_key", unique: true
      t.index ["organization_id", "created_at"], name: "index_disk_imports_on_organization_id_and_created_at"
      t.index ["target_node_id"], name: "index_disk_imports_on_target_node_id"
    end

    create_table "disk_key_grants", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.integer "epoch", null: false
      t.bigint "granted_by_membership_id"
      t.string "key", null: false
      t.bigint "membership_id", null: false
      t.bigint "organization_id", null: false
      t.bigint "scope_node_id", null: false
      t.binary "sealed_key", null: false
      t.binary "signature"
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_disk_key_grants_on_key", unique: true
      t.index ["membership_id"], name: "index_disk_key_grants_on_membership_id"
      t.index ["scope_node_id", "membership_id", "epoch"], name: "index_disk_key_grants_on_scope_member_epoch", unique: true
    end

    create_table "disk_links", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.bigint "created_by_membership_id"
      t.datetime "expires_at"
      t.boolean "hide_download", default: false, null: false
      t.binary "kdf_salt"
      t.integer "kdf_version"
      t.string "key", null: false
      t.datetime "last_used_at"
      t.bigint "node_id", null: false
      t.bigint "organization_id", null: false
      t.string "password_verifier_digest"
      t.datetime "revoked_at"
      t.string "token_digest", null: false
      t.datetime "updated_at", null: false
      t.bigint "version_id"
      t.binary "wrap_key_sealed"
      t.binary "wrapped_payload"
      t.index ["key"], name: "index_disk_links_on_key", unique: true
      t.index ["node_id"], name: "index_disk_links_on_node_id"
      t.index ["organization_id"], name: "index_disk_links_on_organization_id"
      t.index ["token_digest"], name: "index_disk_links_on_token_digest", unique: true
    end

    create_table "disk_nodes", force: :cascade do |t|
      t.bigint "change_seq"
      t.bigint "change_xid"
      t.datetime "content_modified_at"
      t.datetime "created_at", null: false
      t.bigint "created_by_membership_id"
      t.bigint "current_version_id"
      t.bigint "custodian_membership_id"
      t.string "key", null: false
      t.integer "key_epoch"
      t.string "kind", null: false
      t.binary "listing_digest"
      t.integer "listing_revision", default: 0, null: false
      t.binary "listing_signature"
      t.bigint "listing_signer_membership_id"
      t.binary "metadata_ciphertext"
      t.string "mime"
      t.bigint "modified_by_membership_id"
      t.string "name"
      t.bigint "organization_id", null: false
      t.bigint "original_parent_id"
      t.bigint "parent_id"
      t.datetime "pending_until"
      t.boolean "rotation_due", default: false, null: false
      t.integer "scope_epoch"
      t.binary "scope_parent_wrapped_key"
      t.bigint "seal_scope_node_id"
      t.boolean "sealed", default: false, null: false
      t.bigint "share_id"
      t.bigint "size_bytes", default: 0, null: false
      t.datetime "switched_at"
      t.boolean "trash_root", default: false, null: false
      t.datetime "trashed_at"
      t.bigint "trashed_by_membership_id"
      t.datetime "updated_at", null: false
      t.index "lower((name)::text) gin_trgm_ops", name: "index_disk_nodes_on_name_trgm", using: :gin
      t.index "organization_id, parent_id, kind, lower((name)::text)", name: "index_disk_nodes_on_org_parent_kind_name"
      t.index "parent_id, lower((name)::text)", name: "index_disk_nodes_unique_name_in_folder", unique: true, where: "((name IS NOT NULL) AND (trashed_at IS NULL))"
      t.index ["current_version_id"], name: "index_disk_nodes_on_current_version_id"
      t.index ["custodian_membership_id"], name: "index_disk_nodes_on_custodian_membership_id"
      t.index ["custodian_membership_id"], name: "index_disk_nodes_one_root_per_custodian", unique: true, where: "((parent_id IS NULL) AND (custodian_membership_id IS NOT NULL))"
      t.index ["key"], name: "index_disk_nodes_on_key", unique: true
      t.index ["organization_id", "change_xid", "change_seq"], name: "index_disk_nodes_on_sync_cursor"
      t.index ["organization_id", "parent_id", "content_modified_at"], name: "index_disk_nodes_on_org_parent_modified"
      t.index ["organization_id", "parent_id", "size_bytes"], name: "index_disk_nodes_on_org_parent_size"
      t.index ["organization_id", "trashed_at"], name: "index_disk_nodes_on_org_trash", where: "trash_root"
      t.index ["parent_id"], name: "index_disk_nodes_on_parent_id"
      t.index ["pending_until"], name: "index_disk_nodes_on_pending_until", where: "(pending_until IS NOT NULL)"
      t.index ["seal_scope_node_id"], name: "index_disk_nodes_on_seal_scope_node_id"
      t.index ["share_id"], name: "index_disk_nodes_on_share_id"
      t.index ["share_id"], name: "index_disk_nodes_one_root_per_share", unique: true, where: "((parent_id IS NULL) AND (share_id IS NOT NULL))"
      t.index ["switched_at"], name: "index_disk_nodes_on_switched_at", where: "(switched_at IS NOT NULL)"
      t.check_constraint "(share_id IS NULL) <> (custodian_membership_id IS NULL)", name: "disk_nodes_one_drive"
      t.check_constraint "sealed AND name IS NULL AND mime IS NULL OR NOT sealed AND metadata_ciphertext IS NULL", name: "disk_nodes_sealed_identity"
    end

    create_table "disk_page_updates", force: :cascade do |t|
      t.binary "ciphertext", null: false
      t.datetime "created_at", null: false
      t.integer "epoch", null: false
      t.bigint "node_id", null: false
      t.bigint "organization_id", null: false
      t.bigint "seq", null: false
      t.index ["node_id", "seq"], name: "index_disk_page_updates_on_node_id_and_seq", unique: true
    end

    create_table "disk_page_versions", force: :cascade do |t|
      t.bigint "author_membership_id"
      t.datetime "created_at", null: false
      t.text "markdown"
      t.bigint "node_id", null: false
      t.bigint "organization_id", null: false
      t.integer "revision", null: false
      t.binary "sealed_snapshot"
      t.integer "snapshot_epoch"
      t.bigint "snapshot_seq"
      t.datetime "updated_at", null: false
      t.binary "ydoc"
      t.index ["node_id", "created_at"], name: "index_disk_page_versions_on_node_id_and_created_at"
      t.index ["node_id", "revision"], name: "index_disk_page_versions_on_node_id_and_revision", unique: true
    end

    create_table "disk_pages", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.text "markdown"
      t.bigint "node_id", null: false
      t.bigint "organization_id", null: false
      t.integer "revision", default: 0, null: false
      t.binary "sealed_snapshot"
      t.integer "snapshot_epoch"
      t.bigint "snapshot_seq"
      t.bigint "update_seq", default: 0, null: false
      t.datetime "updated_at", null: false
      t.binary "ydoc"
      t.index ["node_id"], name: "index_disk_pages_on_node_id", unique: true
    end

    create_table "disk_recents", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.bigint "membership_id", null: false
      t.bigint "node_id", null: false
      t.bigint "organization_id", null: false
      t.datetime "updated_at", null: false
      t.index ["membership_id", "created_at"], name: "index_disk_recents_on_membership_id_and_created_at"
      t.index ["node_id", "membership_id"], name: "index_disk_recents_on_node_id_and_membership_id", unique: true
    end

    create_table "disk_scope_epochs", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.bigint "created_by_membership_id"
      t.integer "epoch", null: false
      t.bigint "organization_id", null: false
      t.binary "previous_key_wrapped"
      t.bigint "scope_node_id", null: false
      t.datetime "updated_at", null: false
      t.index ["scope_node_id", "epoch"], name: "index_disk_scope_epochs_on_scope_node_id_and_epoch", unique: true
    end

    create_table "disk_share_memberships", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.bigint "membership_id", null: false
      t.bigint "organization_id", null: false
      t.string "role", null: false
      t.bigint "share_id", null: false
      t.datetime "updated_at", null: false
      t.index ["membership_id"], name: "index_disk_share_memberships_on_membership_id"
      t.index ["share_id", "membership_id"], name: "index_disk_share_memberships_on_share_and_membership", unique: true
    end

    create_table "disk_shares", force: :cascade do |t|
      t.datetime "archived_at"
      t.string "color"
      t.datetime "created_at", null: false
      t.bigint "domain_id"
      t.string "icon"
      t.string "key", null: false
      t.string "name", null: false
      t.string "openness", default: "assigned", null: false
      t.string "org_role", default: "view", null: false
      t.bigint "organization_id", null: false
      t.datetime "purge_at"
      t.bigint "root_node_id"
      t.string "slug"
      t.datetime "trashed_at"
      t.bigint "trashed_by_membership_id"
      t.datetime "updated_at", null: false
      t.index "organization_id, COALESCE(domain_id, (0)::bigint), lower((name)::text)", name: "index_disk_shares_on_org_domain_and_lower_name", unique: true, where: "(trashed_at IS NULL)"
      t.index ["domain_id"], name: "index_disk_shares_on_domain_id"
      t.index ["organization_id", "slug"], name: "index_disk_shares_on_org_and_slug", unique: true, where: "(trashed_at IS NULL)"
      t.index ["key"], name: "index_disk_shares_on_key", unique: true
      t.index ["root_node_id"], name: "index_disk_shares_on_root_node_id"
    end

    create_table "disk_stars", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.bigint "membership_id", null: false
      t.bigint "node_id", null: false
      t.bigint "organization_id", null: false
      t.datetime "updated_at", null: false
      t.index ["membership_id", "created_at"], name: "index_disk_stars_on_membership_id_and_created_at"
      t.index ["node_id", "membership_id"], name: "index_disk_stars_on_node_id_and_membership_id", unique: true
    end

    # Disk sync feed (docs/Disk-Sync.md). Filled by Disk::SyncTriggers, installed by
    # 20261122130001 — a roll-up must keep a `Disk::SyncTriggers.ensure!` call.
    create_table "disk_sync_events", force: :cascade do |t|
      t.bigint "change_seq", null: false
      t.bigint "change_xid", null: false
      t.datetime "created_at", null: false
      t.string "kind", null: false
      t.string "node_key"
      t.bigint "organization_id", null: false
      t.index ["organization_id", "change_xid", "change_seq"], name: "index_disk_sync_events_on_sync_cursor"
      t.index ["organization_id", "created_at"], name: "index_disk_sync_events_on_organization_id_and_created_at"
    end

    create_table "disk_upload_parts", force: :cascade do |t|
      t.datetime "issued_at", null: false
      t.integer "number", null: false
      t.bigint "organization_id", null: false
      t.bigint "upload_id", null: false
      t.index ["upload_id", "number"], name: "index_disk_upload_parts_on_upload_id_and_number", unique: true
    end

    create_table "disk_uploads", force: :cascade do |t|
      t.string "base_version_key"
      t.integer "chunk_bytes"
      t.datetime "created_at", null: false
      t.bigint "declared_bytes", null: false
      t.datetime "expires_at", null: false
      t.string "idempotency_key"
      t.binary "intended_metadata_ciphertext"
      t.string "intended_name"
      t.string "key", null: false
      t.integer "key_epoch"
      t.binary "manifest_ciphertext"
      t.bigint "membership_id", null: false
      t.string "multipart_upload_id"
      t.bigint "node_id"
      t.string "node_key", null: false
      t.bigint "organization_id", null: false
      t.bigint "parent_id"
      t.bigint "part_bytes", null: false
      t.boolean "sealed", default: false, null: false
      t.string "sha256"
      t.boolean "staged", default: false, null: false
      t.string "state", default: "reserved", null: false
      t.string "storage_key", null: false
      t.datetime "updated_at", null: false
      t.string "version_key", null: false
      t.binary "wrapped_key"
      t.index ["key"], name: "index_disk_uploads_on_key", unique: true
      t.index ["membership_id", "idempotency_key"], name: "index_disk_uploads_on_membership_id_and_idempotency_key", unique: true
      t.index ["state", "expires_at"], name: "index_disk_uploads_on_state_and_expires_at"
      t.index ["storage_key"], name: "index_disk_uploads_on_storage_key", unique: true
      t.check_constraint "sealed AND intended_name IS NULL OR NOT sealed AND intended_metadata_ciphertext IS NULL", name: "disk_uploads_sealed_identity"
    end

    create_table "disk_versions", force: :cascade do |t|
      t.bigint "author_membership_id"
      t.integer "chunk_bytes"
      t.datetime "created_at", null: false
      t.datetime "expires_at"
      t.string "key", null: false
      t.integer "key_epoch"
      t.binary "manifest_ciphertext"
      t.bigint "node_id", null: false
      t.integer "number", null: false
      t.bigint "organization_id", null: false
      t.string "rendition_storage_key"
      t.string "sha256"
      t.bigint "size_bytes", default: 0, null: false
      t.string "storage_key", null: false
      t.string "thumbnail_storage_key"
      t.datetime "updated_at", null: false
      t.binary "wrapped_key"
      t.index ["expires_at"], name: "index_disk_versions_on_expires_at"
      t.index ["key"], name: "index_disk_versions_on_key", unique: true
      t.index ["node_id", "created_at"], name: "index_disk_versions_on_node_id_and_created_at"
      t.index ["node_id", "number"], name: "index_disk_versions_on_node_id_and_number", unique: true
      t.index ["storage_key"], name: "index_disk_versions_on_storage_key", unique: true
    end

    create_table "domain_key_grants", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.bigint "domain_key_id", null: false
      t.string "key", null: false
      t.bigint "membership_id", null: false
      t.text "sealed_secret_key", null: false
      t.datetime "updated_at", null: false
      t.index ["domain_key_id", "membership_id"], name: "index_domain_key_grants_on_domain_key_and_membership", unique: true
      t.index ["key"], name: "index_domain_key_grants_on_key", unique: true
      t.index ["membership_id"], name: "index_domain_key_grants_on_membership_id"
    end

    create_table "domain_keys", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.bigint "domain_id", null: false
      t.string "key", null: false
      t.text "public_key", null: false
      t.datetime "retired_at"
      t.datetime "updated_at", null: false
      t.integer "version", null: false
      t.index ["domain_id", "version"], name: "index_domain_keys_on_domain_id_and_version", unique: true
      t.index ["key"], name: "index_domain_keys_on_key", unique: true
    end

    create_table "domains", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.datetime "dns_checked_at"
      t.jsonb "dns_checks", default: {}, null: false
      t.boolean "e2ee_enabled", default: false, null: false
      t.boolean "e2ee_notification_preview", default: true, null: false
      t.string "icon_url"
      t.string "key", null: false
      t.boolean "link_tracking_enabled", default: false, null: false
      t.datetime "locked_at"
      t.string "name", null: false
      t.boolean "open_tracking_enabled", default: false, null: false
      t.bigint "organization_id", null: false
      t.jsonb "shared_addresses", default: [], null: false
      t.string "status", default: "pending_dns", null: false
      t.string "tracking_cf_hostname_id"
      t.string "tracking_domain"
      t.datetime "tracking_domain_verified_at"
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_domains_on_key", unique: true
      t.index ["name"], name: "index_domains_on_name", unique: true
      t.index ["organization_id"], name: "index_domains_on_organization_id"
    end

    create_table "esp_deliveries", force: :cascade do |t|
      t.string "key", null: false
      t.bigint "organization_id", null: false
      t.bigint "esp_message_id", null: false
      t.string "recipient", null: false
      t.string "status", default: "queued", null: false
      t.string "bounce_token", null: false
      t.integer "attempt_count", default: 0, null: false
      t.string "smtp_code"
      t.text "response"
      t.string "mx_host"
      t.datetime "published_at"
      t.datetime "delivered_at"
      t.datetime "failed_at"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["bounce_token"], name: "index_esp_deliveries_on_bounce_token", unique: true
      t.index ["esp_message_id"], name: "index_esp_deliveries_on_esp_message_id"
      t.index ["key"], name: "index_esp_deliveries_on_key", unique: true
      t.index ["organization_id", "created_at"], name: "index_esp_deliveries_on_organization_id_and_created_at"
      t.index ["organization_id", "recipient"], name: "index_esp_deliveries_on_organization_id_and_recipient"
      t.index ["organization_id"], name: "index_esp_deliveries_on_organization_id"
    end

    create_table "esp_domains", force: :cascade do |t|
      t.string "key", null: false
      t.bigint "organization_id", null: false
      t.string "name", null: false
      t.string "status", default: "pending_dns", null: false
      t.jsonb "dns_checks", default: {}, null: false
      t.datetime "dns_checked_at"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index "lower((name)::text)", name: "index_esp_domains_on_lower_name", unique: true
      t.index ["key"], name: "index_esp_domains_on_key", unique: true
      t.index ["organization_id"], name: "index_esp_domains_on_organization_id"
    end

    create_table "esp_events", force: :cascade do |t|
      t.string "key", null: false
      t.bigint "organization_id", null: false
      t.bigint "esp_message_id", null: false
      t.bigint "esp_delivery_id", null: false
      t.string "kind", null: false
      t.jsonb "detail", default: {}, null: false
      t.datetime "created_at", null: false
      t.index ["esp_delivery_id"], name: "index_esp_events_on_esp_delivery_id"
      t.index ["esp_message_id"], name: "index_esp_events_on_esp_message_id"
      t.index ["key"], name: "index_esp_events_on_key", unique: true
      t.index ["organization_id"], name: "index_esp_events_on_organization_id"
    end

    create_table "esp_keys", force: :cascade do |t|
      t.string "key", null: false
      t.bigint "organization_id", null: false
      t.bigint "created_by_id"
      t.string "name", null: false
      t.string "prefix", null: false
      t.string "token_digest", null: false
      t.datetime "last_used_at"
      t.datetime "revoked_at"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["created_by_id"], name: "index_esp_keys_on_created_by_id"
      t.index ["key"], name: "index_esp_keys_on_key", unique: true
      t.index ["organization_id"], name: "index_esp_keys_on_organization_id"
      t.index ["prefix"], name: "index_esp_keys_on_prefix", unique: true
    end

    create_table "esp_messages", force: :cascade do |t|
      t.string "key", null: false
      t.bigint "organization_id", null: false
      t.bigint "esp_key_id", null: false
      t.string "from_address", null: false
      t.text "to_address", null: false
      t.text "cc_address"
      t.text "bcc_address"
      t.string "reply_to"
      t.string "subject"
      t.string "tag"
      t.jsonb "metadata", default: {}, null: false
      t.string "message_id_header", null: false
      t.string "idempotency_key"
      t.binary "raw_mime"
      t.integer "size_bytes", default: 0, null: false
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["esp_key_id"], name: "index_esp_messages_on_esp_key_id"
      t.index ["key"], name: "index_esp_messages_on_key", unique: true
      t.index ["message_id_header"], name: "index_esp_messages_on_message_id_header"
      t.index ["organization_id", "created_at"], name: "index_esp_messages_on_organization_id_and_created_at"
      t.index ["organization_id", "idempotency_key"], name: "index_esp_messages_on_org_and_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
      t.index ["organization_id"], name: "index_esp_messages_on_organization_id"
    end

    create_table "external_busy_blocks", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.datetime "end_at", null: false
      t.bigint "membership_id", null: false
      t.bigint "organization_id", null: false
      t.string "source", null: false
      t.datetime "start_at", null: false
      t.datetime "updated_at", null: false
      t.index ["membership_id", "source"], name: "index_external_busy_blocks_on_membership_source"
      t.index ["organization_id", "start_at", "end_at"], name: "index_external_busy_blocks_on_org_range"
    end

    create_table "imap_folders", force: :cascade do |t|
      t.bigint "membership_id", null: false
      t.string "name", null: false
      t.bigint "uidvalidity", null: false
      t.bigint "uidnext", default: 1, null: false
      t.index ["membership_id", "name"], name: "index_imap_folders_on_membership_id_and_name", unique: true
    end

    create_table "imap_messages", force: :cascade do |t|
      t.bigint "membership_id", null: false
      t.bigint "message_id", null: false
      t.string "folder", null: false
      t.bigint "uid", null: false
      t.string "flags", default: [], null: false, array: true
      t.boolean "expunged", default: false, null: false
      t.integer "size"
      t.index ["membership_id", "folder", "uid"], name: "index_imap_messages_on_membership_id_and_folder_and_uid", unique: true
      t.index ["membership_id", "message_id"], name: "index_imap_messages_on_membership_id_and_message_id", unique: true
      t.index ["message_id"], name: "index_imap_messages_on_message_id"
    end

    create_table "integrations", force: :cascade do |t|
      t.string "access_token_digest"
      t.jsonb "config", default: {}
      t.datetime "created_at", null: false
      t.jsonb "events", default: []
      t.string "key", null: false
      t.string "name", null: false
      t.bigint "organization_id", null: false
      t.string "provider", null: false
      t.string "refresh_token_digest"
      t.string "status", default: "active", null: false
      t.datetime "token_expires_at"
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_integrations_on_key", unique: true
      t.index ["organization_id", "provider"], name: "index_integrations_on_organization_id_and_provider"
      t.index ["organization_id"], name: "index_integrations_on_organization_id"
    end

    create_table "lore_entities", force: :cascade do |t|
      t.string "address"
      t.datetime "created_at", null: false
      t.bigint "domain_id", null: false
      t.string "email_domain"
      t.datetime "first_seen_at"
      t.string "key", null: false
      t.string "kind", null: false
      t.datetime "last_seen_at"
      t.integer "mention_count", default: 0, null: false
      t.bigint "merged_into_id"
      t.string "name", null: false
      t.boolean "name_locked", default: false, null: false
      t.string "normalized_name", null: false
      t.bigint "organization_id", null: false
      t.datetime "removed_at"
      t.datetime "updated_at", null: false
      t.index ["domain_id", "kind", "normalized_name"], name: "idx_lore_entities_identity", unique: true
      t.index ["key"], name: "index_lore_entities_on_key", unique: true
      t.index ["organization_id", "mention_count"], name: "index_lore_entities_on_organization_id_and_mention_count"
    end

    create_table "lore_facts", force: :cascade do |t|
      t.float "confidence", default: 1.0, null: false
      t.bigint "conversation_id"
      t.datetime "created_at", null: false
      t.string "fingerprint", null: false
      t.float "grounding", default: 1.0, null: false
      t.string "kind", null: false
      t.bigint "lore_entity_id", null: false
      t.bigint "message_id"
      t.string "name", null: false
      t.text "quote"
      t.bigint "related_entity_id"
      t.datetime "removed_at"
      t.integer "support", default: 1, null: false
      t.text "value"
      t.index ["conversation_id"], name: "index_lore_facts_on_conversation_id"
      t.index ["lore_entity_id", "fingerprint"], name: "index_lore_facts_on_lore_entity_id_and_fingerprint", unique: true
      t.index ["related_entity_id"], name: "index_lore_facts_on_related_entity_id"
    end

    create_table "lore_member_dones", force: :cascade do |t|
      t.bigint "conversation_id", null: false
      t.datetime "created_at", null: false
      t.bigint "membership_id", null: false
      t.datetime "updated_at", null: false
      t.index ["conversation_id", "membership_id"], name: "index_lore_member_dones_on_conversation_id_and_membership_id", unique: true
      t.index ["membership_id"], name: "index_lore_member_dones_on_membership_id"
    end

    create_table "lore_mentions", force: :cascade do |t|
      t.bigint "conversation_id", null: false
      t.datetime "created_at", null: false
      t.bigint "lore_entity_id", null: false
      t.index ["conversation_id"], name: "index_lore_mentions_on_conversation_id"
      t.index ["lore_entity_id", "conversation_id"], name: "index_lore_mentions_on_lore_entity_id_and_conversation_id", unique: true
    end

    create_table "mail_auth_reports", force: :cascade do |t|
      t.datetime "begin_at"
      t.datetime "created_at", null: false
      t.string "domain"
      t.datetime "end_at"
      t.integer "failure_count", default: 0, null: false
      t.string "key", null: false
      t.string "kind", null: false
      t.bigint "organization_id", null: false
      t.string "report_id"
      t.string "reporter"
      t.jsonb "summary", default: {}
      t.integer "total_count", default: 0, null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_mail_auth_reports_on_key", unique: true
      t.index ["organization_id", "created_at"], name: "index_mail_auth_reports_on_organization_id_and_created_at"
      t.index ["organization_id", "kind", "reporter", "report_id"], name: "index_mail_auth_reports_dedupe"
      t.index ["organization_id"], name: "index_mail_auth_reports_on_organization_id"
    end

    create_table "mail_client_passwords", force: :cascade do |t|
      t.string "key", null: false
      t.bigint "membership_id", null: false
      t.string "name", null: false
      t.string "prefix", null: false
      t.string "token_digest", null: false
      t.datetime "last_used_at"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_mail_client_passwords_on_key", unique: true
      t.index ["membership_id"], name: "index_mail_client_passwords_on_membership_id"
      t.index ["prefix"], name: "index_mail_client_passwords_on_prefix", unique: true
    end

    create_table "mail_filters", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.string "kind", null: false
      t.bigint "organization_id", null: false
      t.datetime "updated_at", null: false
      t.string "value", null: false
      t.index ["key"], name: "index_mail_filters_on_key", unique: true
      t.index ["organization_id", "kind"], name: "index_mail_filters_on_organization_id_and_kind"
      t.index ["organization_id", "value"], name: "index_mail_filters_on_organization_id_and_value", unique: true
    end

    create_table "mail_import_threads", force: :cascade do |t|
      t.bigint "conversation_id", null: false
      t.datetime "created_at", null: false
      t.bigint "mail_import_id", null: false
      t.string "source_thread_id", null: false
      t.datetime "updated_at", null: false
      t.index ["conversation_id"], name: "index_mail_import_threads_on_conversation_id"
      t.index ["mail_import_id", "source_thread_id"], name: "index_mail_import_threads_on_import_and_source", unique: true
    end

    create_table "mail_imports", force: :cascade do |t|
      t.bigint "connection_id"
      t.jsonb "counts", default: {}, null: false
      t.datetime "created_at", null: false
      t.text "cursor"
      t.bigint "domain_id", null: false
      t.text "error"
      t.datetime "finished_at"
      t.string "key", null: false
      t.bigint "membership_id", null: false
      t.bigint "organization_id", null: false
      t.bigint "owner_membership_id", null: false
      t.string "pause_reason"
      t.string "provider", null: false
      t.jsonb "report", default: {}, null: false
      t.string "source_email", null: false
      t.bigint "source_node_id"
      t.integer "run", default: 0, null: false
      t.datetime "started_at"
      t.string "state", null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_mail_imports_on_key", unique: true
      t.index ["organization_id", "provider", "source_email"], name: "index_mail_imports_on_org_provider_source", unique: true
      t.index ["owner_membership_id"], name: "index_mail_imports_on_owner_membership_id"
    end

    create_table "mailbox_aliases", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.bigint "domain_id"
      t.string "key", null: false
      t.string "local_part", null: false
      t.string "mode", null: false
      t.bigint "organization_id", null: false
      t.bigint "target_membership_id"
      t.datetime "updated_at", null: false
      t.index ["domain_id", "local_part"], name: "index_mailbox_aliases_on_domain_and_local_part", unique: true
      t.index ["key"], name: "index_mailbox_aliases_on_key", unique: true
      t.index ["organization_id"], name: "index_mailbox_aliases_on_organization_id"
      t.index ["target_membership_id"], name: "index_mailbox_aliases_on_target_membership_id"
    end

    create_table "mailbox_graph_snapshots", force: :cascade do |t|
      t.datetime "computed_at", null: false
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.bigint "organization_id", null: false
      t.jsonb "payload", default: {}, null: false
      t.string "source_version", null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_mailbox_graph_snapshots_on_key", unique: true
      t.index ["organization_id"], name: "index_mailbox_graph_snapshots_on_organization_id", unique: true
    end

    create_table "mailboxes", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.bigint "domain_id", null: false
      t.string "key", null: false
      t.string "local_part", null: false
      t.bigint "membership_id", null: false
      t.datetime "updated_at", null: false
      t.index ["domain_id", "local_part"], name: "index_mailboxes_on_domain_id_and_local_part", unique: true
      t.index ["key"], name: "index_mailboxes_on_key", unique: true
      t.index ["membership_id"], name: "index_mailboxes_on_membership_id"
    end

    create_table "meet_links", force: :cascade do |t|
      t.string "conference_mode", default: "none", null: false
      t.datetime "created_at", null: false
      t.integer "duration_minutes", default: 30, null: false
      t.bigint "invitee_membership_id", null: false
      t.string "key", null: false
      t.string "label", null: false
      t.integer "max_ahead_days", default: 28, null: false
      t.bigint "membership_id", null: false
      t.integer "min_notice_minutes", default: 240, null: false
      t.bigint "organization_id", null: false
      t.integer "requests_count", default: 0, null: false
      t.datetime "revoked_at"
      t.string "token", null: false
      t.datetime "updated_at", null: false
      t.integer "visits_count", default: 0, null: false
      t.index ["key"], name: "index_meet_links_on_key", unique: true
      t.index ["organization_id", "membership_id"], name: "index_meet_links_on_organization_id_and_membership_id"
      t.index ["token"], name: "index_meet_links_on_token", unique: true
    end

    create_table "meeting_requests", force: :cascade do |t|
      t.bigint "calendar_event_id"
      t.datetime "created_at", null: false
      t.text "decline_reason"
      t.string "email", null: false
      t.datetime "end_at", null: false
      t.string "key", null: false
      t.bigint "meet_link_id", null: false
      t.bigint "message_id"
      t.string "name", null: false
      t.text "note"
      t.bigint "organization_id", null: false
      t.datetime "start_at", null: false
      t.string "status", default: "pending", null: false
      t.datetime "updated_at", null: false
      t.string "visitor_timezone"
      t.index ["key"], name: "index_meeting_requests_on_key", unique: true
      t.index ["meet_link_id", "status"], name: "index_meeting_requests_on_meet_link_id_and_status"
      t.index ["organization_id"], name: "index_meeting_requests_on_organization_id"
    end

    create_table "member_groups", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.string "name", null: false
      t.bigint "organization_id", null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_member_groups_on_key", unique: true
      t.index ["organization_id"], name: "index_member_groups_on_organization_id"
    end

    create_table "membership_domains", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.bigint "domain_id", null: false
      t.bigint "membership_id", null: false
      t.datetime "updated_at", null: false
      t.index ["domain_id"], name: "index_membership_domains_on_domain_id"
      t.index ["membership_id", "domain_id"], name: "index_membership_domains_on_membership_and_domain", unique: true
      t.index ["membership_id"], name: "index_membership_domains_on_membership_id"
    end

    create_table "memberships", force: :cascade do |t|
      t.boolean "all_domains", default: true, null: false
      t.boolean "available", default: true, null: false
      t.datetime "billing_locked_at"
      t.datetime "created_at", null: false
      t.string "drive_letter", limit: 1
      t.boolean "exclude_personal_mailboxes", default: false, null: false
      t.jsonb "folder_prefs", default: {}, null: false
      t.string "invite_token_digest"
      t.string "key", null: false
      t.string "member_type", default: "human", null: false
      t.bigint "organization_id", null: false
      t.string "role", default: "member", null: false
      t.string "send_as_addresses", default: [], null: false, array: true
      t.string "status", default: "active", null: false
      t.datetime "updated_at", null: false
      t.bigint "user_id", null: false
      t.index ["invite_token_digest"], name: "index_memberships_on_invite_token_digest", unique: true, where: "(invite_token_digest IS NOT NULL)"
      t.index ["key"], name: "index_memberships_on_key", unique: true
      t.index ["organization_id"], name: "index_memberships_on_organization_id"
      t.index ["user_id", "organization_id"], name: "index_memberships_on_user_id_and_organization_id", unique: true
      t.index ["user_id"], name: "index_memberships_on_user_id"
    end

    create_table "messages", force: :cascade do |t|
      t.string "auto_submitted"
      t.string "bcc_address"
      t.text "body_ciphertext"
      t.text "body_html"
      t.text "body_nonce"
      t.text "body_plain"
      t.jsonb "calendar_invite"
      t.text "calendar_reply"
      t.string "cc_address"
      t.bigint "change_seq"
      t.bigint "change_xid"
      t.string "content_type", default: "text/plain"
      t.bigint "conversation_id", null: false
      t.datetime "created_at", null: false
      t.jsonb "detected_meeting"
      t.integer "domain_key_version"
      t.string "encryption_scheme", default: "none", null: false
      t.string "from_address"
      t.text "header_ciphertext"
      t.text "header_nonce"
      t.string "in_reply_to"
      t.boolean "is_draft", default: false, null: false
      t.boolean "is_inbound", default: true, null: false
      t.string "key", null: false
      t.jsonb "meeting_request"
      t.string "message_id_header"
      t.string "msgid_hmac"
      t.bigint "organization_id", null: false
      t.bigint "owner_membership_id"
      t.text "raw_headers"
      t.text "references_header"
      t.string "refs_hmac", default: [], null: false, array: true
      t.string "rsvp_status"
      t.datetime "scheduled_at", precision: nil
      t.text "seal_aad"
      t.text "sealed_dek"
      t.text "sealed_mime"
      t.tsvector "search_vector"
      t.bigint "sender_membership_id"
      t.string "spam_action"
      t.decimal "spam_score", precision: 5, scale: 2
      t.jsonb "spam_symbols", default: []
      t.string "subject"
      t.string "subject_hmac"
      t.string "to_address"
      t.string "tracking_token"
      t.datetime "updated_at", null: false
      t.index "organization_id, message_id_header, COALESCE(owner_membership_id, (0)::bigint)", name: "index_messages_on_org_message_id_owner", unique: true, where: "(message_id_header IS NOT NULL)"
      t.index "organization_id, msgid_hmac, COALESCE(owner_membership_id, (0)::bigint)", name: "index_messages_on_org_msgid_hmac_owner", unique: true, where: "(msgid_hmac IS NOT NULL)"
      t.index ["conversation_id", "created_at"], name: "index_messages_on_conversation_id_and_created_at"
      t.index ["conversation_id"], name: "index_messages_on_conversation_id"
      t.index ["is_draft"], name: "index_messages_on_is_draft"
      t.index ["key"], name: "index_messages_on_key", unique: true
      t.index ["organization_id", "change_xid", "change_seq"], name: "index_messages_on_sync_cursor", where: "(change_seq IS NOT NULL)"
      t.index ["organization_id", "from_address"], name: "index_messages_on_org_id_and_from_address"
      t.index ["organization_id", "subject_hmac"], name: "index_messages_on_org_id_and_subject_hmac"
      t.index ["organization_id"], name: "index_messages_on_organization_id"
      t.index ["refs_hmac"], name: "index_messages_on_refs_hmac", using: :gin
      t.index ["scheduled_at"], name: "index_messages_on_scheduled_at"
      t.index ["search_vector"], name: "index_messages_on_search_vector", using: :gin
      t.index ["spam_score"], name: "index_messages_on_spam_score"
      t.index ["tracking_token"], name: "index_messages_on_tracking_token", unique: true, where: "(tracking_token IS NOT NULL)"
    end

    create_table "message_opens", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.string "geo_city"
      t.string "geo_country"
      t.string "ip"
      t.string "key", null: false
      t.datetime "opened_at", null: false
      t.bigint "organization_id"
      t.boolean "proxied", default: false, null: false
      t.string "proxy_kind"
      t.string "token", null: false
      t.datetime "updated_at", null: false
      t.text "user_agent"
      t.index ["key"], name: "index_message_opens_on_key", unique: true
      t.index ["organization_id"], name: "index_message_opens_on_organization_id"
      t.index ["token", "opened_at"], name: "index_message_opens_on_token_and_opened_at"
      t.index ["token"], name: "index_message_opens_on_token"
    end

    create_table "link_clicks", force: :cascade do |t|
      t.datetime "clicked_at", null: false
      t.datetime "created_at", null: false
      t.string "geo_city"
      t.string "geo_country"
      t.string "ip"
      t.string "key", null: false
      t.bigint "organization_id"
      t.boolean "proxied", default: false, null: false
      t.string "proxy_kind"
      t.string "token", null: false
      t.datetime "updated_at", null: false
      t.text "user_agent"
      t.index ["key"], name: "index_link_clicks_on_key", unique: true
      t.index ["organization_id"], name: "index_link_clicks_on_organization_id"
      t.index ["token", "clicked_at"], name: "index_link_clicks_on_token_and_clicked_at"
      t.index ["token"], name: "index_link_clicks_on_token"
    end

    create_table "tracked_links", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.string "message_tracking_token", null: false
      t.bigint "organization_id"
      t.string "token", null: false
      t.datetime "updated_at", null: false
      t.text "url", null: false
      t.index ["key"], name: "index_tracked_links_on_key", unique: true
      t.index ["message_tracking_token"], name: "index_tracked_links_on_message_tracking_token"
      t.index ["organization_id"], name: "index_tracked_links_on_organization_id"
      t.index ["token"], name: "index_tracked_links_on_token", unique: true
    end

    create_table "meta_channel_subscriptions", force: :cascade do |t|
      t.string "asset_id", null: false
      t.string "asset_type", null: false
      t.string "channel", null: false
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.datetime "last_seen_at"
      t.datetime "lease_expires_at"
      t.string "status", default: "active", null: false
      t.datetime "updated_at", null: false
      t.bigint "user_id", null: false
      t.index ["asset_type", "asset_id"], name: "index_meta_channel_subscriptions_on_asset"
      t.index ["key"], name: "index_meta_channel_subscriptions_on_key", unique: true
      t.index ["user_id", "asset_type", "asset_id"], name: "index_meta_channel_subscriptions_on_user_asset", unique: true
      t.index ["user_id"], name: "index_meta_channel_subscriptions_on_user_id"
    end

    create_table "meta_webhook_events", force: :cascade do |t|
      t.string "asset_id"
      t.datetime "consumed_at"
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.string "object", null: false
      t.string "provider_event_id", null: false
      t.text "raw_payload", null: false
      t.datetime "received_at", null: false
      t.string "signature_header"
      t.datetime "updated_at", null: false
      t.bigint "user_id", null: false
      t.index ["key"], name: "index_meta_webhook_events_on_key", unique: true
      t.index ["provider_event_id"], name: "index_meta_webhook_events_on_provider_event_id", unique: true
      t.index ["received_at"], name: "index_meta_webhook_events_on_received_at"
      t.index ["user_id", "consumed_at"], name: "index_meta_webhook_events_on_user_consumed"
    end

    create_table "mta_sts_policies", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.bigint "domain_id", null: false
      t.boolean "enabled", default: false, null: false
      t.string "key", null: false
      t.integer "max_age", default: 86400, null: false
      t.string "mode", default: "testing", null: false
      t.text "mx_hosts"
      t.datetime "updated_at", null: false
      t.index ["domain_id"], name: "index_mta_sts_policies_on_domain_id", unique: true
      t.index ["key"], name: "index_mta_sts_policies_on_key", unique: true
    end

    create_table "note_reactions", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.string "emoji", null: false
      t.bigint "membership_id", null: false
      t.bigint "note_id", null: false
      t.datetime "updated_at", null: false
      t.index ["membership_id"], name: "index_note_reactions_on_membership_id"
      t.index ["note_id", "membership_id", "emoji"], name: "index_note_reactions_on_note_id_and_membership_id_and_emoji", unique: true
      t.index ["note_id"], name: "index_note_reactions_on_note_id"
    end

    create_table "notes", force: :cascade do |t|
      t.text "body", null: false
      t.bigint "change_seq"
      t.bigint "change_xid"
      t.bigint "conversation_id", null: false
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.bigint "membership_id", null: false
      t.bigint "organization_id", null: false
      t.bigint "parent_note_id"
      t.datetime "updated_at", null: false
      t.index ["conversation_id"], name: "index_notes_on_conversation_id"
      t.index ["key"], name: "index_notes_on_key", unique: true
      t.index ["organization_id"], name: "index_notes_on_organization_id"
      t.index ["parent_note_id"], name: "index_notes_on_parent_note_id"
      t.index ["organization_id", "change_xid", "change_seq"], name: "index_notes_on_sync_cursor", where: "(change_seq IS NOT NULL)"
    end

    create_table "notifications", force: :cascade do |t|
      t.bigint "actor_membership_id"
      t.text "body"
      t.bigint "conversation_id"
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.string "kind", null: false
      t.bigint "organization_id", null: false
      t.boolean "read", default: false, null: false
      t.string "title", null: false
      t.datetime "updated_at", null: false
      t.string "url"
      t.bigint "user_id", null: false
      t.index ["key"], name: "index_notifications_on_key", unique: true
      t.index ["organization_id"], name: "index_notifications_on_organization_id"
      t.index ["user_id", "read"], name: "index_notifications_on_user_id_and_read"
    end

    create_table "oauth_apps", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.bigint "created_by_id"
      t.string "icon_url"
      t.string "key", null: false
      t.string "name", null: false
      t.bigint "organization_id", null: false
      t.jsonb "redirect_uris", default: [], null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_oauth_apps_on_key", unique: true
      t.index ["organization_id", "name"], name: "index_oauth_apps_on_organization_id_and_name", unique: true
    end

    create_table "oauth_grants", force: :cascade do |t|
      t.text "access_token"
      t.string "callback_uri"
      t.string "client_state"
      t.datetime "created_at", null: false
      t.string "email"
      t.datetime "expires_at", null: false
      t.string "key", null: false
      t.bigint "oauth_app_id", null: false
      t.string "provider", null: false
      t.string "redirect_uri", null: false
      t.text "refresh_token"
      t.text "scope"
      t.string "status", default: "pending", null: false
      t.datetime "token_expires_at"
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_oauth_grants_on_key", unique: true
      t.index ["oauth_app_id"], name: "index_oauth_grants_on_oauth_app_id"
    end

    create_table "oauth_identities", force: :cascade do |t|
      t.string "access_token_digest"
      t.string "avatar_url"
      t.datetime "created_at", null: false
      t.string "email"
      t.string "name"
      t.string "provider", null: false
      t.string "refresh_token_digest"
      t.datetime "token_expires_at"
      t.string "uid", null: false
      t.datetime "updated_at", null: false
      t.bigint "user_id", null: false
      t.index ["provider", "uid"], name: "index_oauth_identities_on_provider_and_uid", unique: true
      t.index ["user_id"], name: "index_oauth_identities_on_user_id"
    end

    create_table "out_of_office_replies", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.bigint "organization_id", null: false
      t.datetime "period_start", null: false
      t.string "sender_address", null: false
      t.datetime "updated_at", null: false
      t.bigint "user_id", null: false
      t.index ["organization_id"], name: "index_ooo_replies_on_organization_id"
      t.index ["user_id", "sender_address", "period_start"], name: "index_ooo_replies_on_user_sender_period", unique: true
    end

    create_table "organizations", force: :cascade do |t|
      t.boolean "activity_tracking_enabled", default: true, null: false
      t.bigint "agency_id"
      t.datetime "created_at", null: false
      t.integer "data_retention_days"
      t.bigint "disk_bytes_reserved", default: 0, null: false
      t.bigint "disk_bytes_used", default: 0, null: false
      t.boolean "disk_links_enabled", default: true, null: false
      t.datetime "disk_lost_at"
      t.integer "disk_quota_notified_level", default: 0, null: false
      t.integer "disk_quota_override_gb"
      t.string "favicon_url"
      t.string "icon_url"
      t.string "key", null: false
      t.string "language", default: "en"
      t.string "logo_url"
      t.datetime "lore_retriaged_at"
      t.boolean "mail_clients_enabled", default: false, null: false
      t.integer "mailbox_limit"
      t.string "name", null: false
      t.bigint "owner_id"
      t.bigint "personal_user_id"
      t.bigint "plan_id"
      t.string "slug"
      t.decimal "spam_threshold", precision: 5, scale: 2, default: "5.0"
      t.datetime "suspended_at"
      t.string "suspended_reason"
      t.string "timezone", default: "UTC"
      t.datetime "updated_at", null: false
      t.string "view_creation_policy", default: "members"
      t.index ["agency_id"], name: "index_organizations_on_agency_id"
      t.index ["key"], name: "index_organizations_on_key", unique: true
      t.index ["owner_id"], name: "index_organizations_on_owner_id"
      t.index ["personal_user_id"], name: "index_organizations_on_personal_user_id", unique: true
      t.index ["plan_id"], name: "index_organizations_on_plan_id"
      t.index ["slug"], name: "index_organizations_on_slug", unique: true
    end

    create_table "plans", force: :cascade do |t|
      t.boolean "ai_triage", default: false, null: false
      t.datetime "created_at", null: false
      t.boolean "disk", default: false, null: false
      t.integer "disk_gb_per_member", default: 0, null: false
      t.boolean "e2ee", default: false, null: false
      t.string "interval", default: "month"
      t.string "key", null: false
      t.integer "max_collaborators", default: 1, null: false
      t.integer "max_domains", default: 1, null: false
      t.integer "max_message_size_mb", default: 20, null: false
      t.string "name", null: false
      t.integer "price_cents", default: 0, null: false
      t.boolean "spam_filter", default: false, null: false
      t.string "stripe_price_id"
      t.string "tier"
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_plans_on_key", unique: true
      t.index ["tier"], name: "index_plans_on_tier", unique: true
    end

    create_table "push_devices", force: :cascade do |t|
      t.integer "channel_unread", default: 0, null: false
      t.datetime "created_at", null: false
      t.string "device_name"
      t.string "environment", default: "production", null: false
      t.string "key", null: false
      t.datetime "last_registered_at"
      t.string "live_activity_start_token"
      t.string "live_activity_token"
      t.string "platform", null: false
      t.string "token", null: false
      t.datetime "updated_at", null: false
      t.bigint "user_id", null: false
      t.index ["key"], name: "index_push_devices_on_key", unique: true
      t.index ["token"], name: "index_push_devices_on_token", unique: true
      t.index ["user_id"], name: "index_push_devices_on_user_id"
    end

    create_table "push_subscriptions", force: :cascade do |t|
      t.string "auth_key", null: false
      t.datetime "created_at", null: false
      t.string "endpoint", null: false
      t.string "p256dh_key", null: false
      t.datetime "updated_at", null: false
      t.string "user_agent"
      t.bigint "user_id", null: false
      t.index ["endpoint"], name: "index_push_subscriptions_on_endpoint", unique: true
      t.index ["user_id"], name: "index_push_subscriptions_on_user_id"
    end

    create_table "rule_logs", force: :cascade do |t|
      t.jsonb "actions_taken", default: []
      t.bigint "conversation_id", null: false
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.string "result", null: false
      t.bigint "rule_id", null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_rule_logs_on_key", unique: true
      t.index ["rule_id", "created_at"], name: "index_rule_logs_on_rule_id_and_created_at"
    end

    create_table "rules", force: :cascade do |t|
      t.jsonb "actions", default: [], null: false
      t.jsonb "branches", default: []
      t.jsonb "conditions", default: [], null: false
      t.datetime "created_at", null: false
      t.jsonb "else_actions", default: []
      t.boolean "enabled", default: true, null: false
      t.string "key", null: false
      t.string "name", null: false
      t.bigint "organization_id", null: false
      t.integer "position", default: 0, null: false
      t.boolean "stop_processing", default: false, null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_rules_on_key", unique: true
      t.index ["organization_id", "position"], name: "index_rules_on_organization_id_and_position"
      t.index ["organization_id"], name: "index_rules_on_organization_id"
    end

    create_table "saas_audit_logs", force: :cascade do |t|
      t.string "action", null: false
      t.bigint "admin_credential_id"
      t.datetime "created_at", null: false
      t.string "ip_address"
      t.string "key", null: false
      t.jsonb "metadata", default: {}, null: false
      t.string "target_key"
      t.string "target_type"
      t.datetime "updated_at", null: false
      t.index ["admin_credential_id"], name: "index_saas_audit_logs_on_admin_credential_id"
      t.index ["created_at"], name: "index_saas_audit_logs_on_created_at"
      t.index ["key"], name: "index_saas_audit_logs_on_key", unique: true
    end

    create_table "saml_assertions", force: :cascade do |t|
      t.string "assertion_id", null: false
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.bigint "organization_id", null: false
      t.datetime "updated_at", null: false
      t.index ["assertion_id"], name: "index_saml_assertions_on_assertion_id", unique: true
      t.index ["key"], name: "index_saml_assertions_on_key", unique: true
      t.index ["organization_id"], name: "index_saml_assertions_on_organization_id"
    end

    create_table "saml_configs", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.boolean "enabled", default: false, null: false
      t.text "idp_certificate", null: false
      t.string "idp_entity_id", null: false
      t.text "idp_sso_url", null: false
      t.string "key", null: false
      t.string "name_id_format", default: "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"
      t.bigint "organization_id", null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_saml_configs_on_key", unique: true
      t.index ["organization_id"], name: "index_saml_configs_on_organization_id", unique: true
    end

    create_table "saml_identities", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.datetime "last_login_at"
      t.string "name_id", null: false
      t.bigint "organization_id", null: false
      t.datetime "updated_at", null: false
      t.bigint "user_id", null: false
      t.index ["key"], name: "index_saml_identities_on_key", unique: true
      t.index ["organization_id", "name_id"], name: "index_saml_identities_on_organization_id_and_name_id", unique: true
      t.index ["user_id"], name: "index_saml_identities_on_user_id"
    end

    create_table "sessions", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.string "ip_address"
      t.datetime "last_active_at"
      t.string "token", null: false
      t.string "token_digest"
      t.datetime "updated_at", null: false
      t.string "user_agent"
      t.bigint "user_id", null: false
      t.index ["token"], name: "index_sessions_on_token", unique: true
      t.index ["token_digest"], name: "index_sessions_on_token_digest", unique: true
      t.index ["user_id"], name: "index_sessions_on_user_id"
    end

    create_table "signatures", force: :cascade do |t|
      t.text "body_html"
      t.datetime "created_at", null: false
      t.string "from_address"
      t.boolean "is_default", default: false, null: false
      t.string "key", null: false
      t.bigint "membership_id"
      t.string "name", null: false
      t.bigint "organization_id", null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_signatures_on_key", unique: true
      t.index ["organization_id"], name: "index_signatures_on_organization_id"
    end

    create_table "space_memberships", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.bigint "membership_id", null: false
      t.bigint "space_id", null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_space_memberships_on_key", unique: true
      t.index ["membership_id"], name: "index_space_memberships_on_membership_id"
      t.index ["space_id", "membership_id"], name: "index_space_memberships_on_space_id_and_membership_id", unique: true
      t.index ["space_id"], name: "index_space_memberships_on_space_id"
    end

    create_table "spaces", force: :cascade do |t|
      t.string "alias_local"
      t.boolean "classify", default: true, null: false
      t.string "color"
      t.datetime "created_at", null: false
      t.text "description"
      t.string "icon"
      t.string "key", null: false
      t.string "name", null: false
      t.text "not_for"
      t.string "openness", default: "assigned", null: false
      t.bigint "organization_id", null: false
      t.integer "position", default: 0, null: false
      t.string "slug", null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_spaces_on_key", unique: true
      t.index ["organization_id", "slug"], name: "index_spaces_on_organization_id_and_slug", unique: true
      t.index ["organization_id"], name: "index_spaces_on_organization_id"
    end

    create_table "stored_credentials", force: :cascade do |t|
      t.text "blob", null: false
      t.text "blob_nonce", null: false
      t.integer "blob_version", default: 0, null: false
      t.datetime "created_at", null: false
      t.string "external_email", null: false
      t.string "key", null: false
      t.string "provider", null: false
      t.datetime "updated_at", null: false
      t.bigint "user_id", null: false
      t.index ["key"], name: "index_stored_credentials_on_key", unique: true
      t.index ["user_id", "provider", "external_email"], name: "index_stored_credentials_on_user_provider_email", unique: true
      t.index ["user_id"], name: "index_stored_credentials_on_user_id"
    end

    create_table "subscriptions", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.datetime "current_period_ends_at"
      t.string "key", null: false
      t.bigint "organization_id", null: false
      t.bigint "plan_id", null: false
      t.string "status", default: "active", null: false
      t.string "stripe_customer_id"
      t.string "stripe_subscription_id"
      t.datetime "trial_ends_at"
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_subscriptions_on_key", unique: true
      t.index ["organization_id"], name: "index_subscriptions_on_organization_id", unique: true
    end

    create_table "suppression_entries", force: :cascade do |t|
      t.string "address", null: false
      t.datetime "created_at", null: false
      t.text "detail"
      t.string "key", null: false
      t.bigint "organization_id", null: false
      t.string "reason", null: false
      t.string "source"
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_suppression_entries_on_key", unique: true
      t.index ["organization_id", "address"], name: "index_suppression_entries_on_org_and_address", unique: true
      t.index ["organization_id"], name: "index_suppression_entries_on_organization_id"
    end

    create_table "tag_groups", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.string "name", null: false
      t.bigint "organization_id", null: false
      t.integer "position", default: 0, null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_tag_groups_on_key", unique: true
      t.index ["organization_id"], name: "index_tag_groups_on_organization_id"
    end

    # MX sync (docs/MX-Sync.md). The triggers that fill this live in SyncTriggers and
    # are installed by 20260920000001 — a roll-up must keep a `SyncTriggers.ensure!` call.
    create_table "sync_tombstones", force: :cascade do |t|
      t.bigint "change_seq", null: false
      t.bigint "change_xid", null: false
      t.datetime "created_at", null: false
      t.bigint "organization_id", null: false
      t.string "parent_key"
      t.string "record_key", null: false
      t.string "record_type", null: false
      t.index ["organization_id", "created_at"], name: "index_sync_tombstones_on_organization_id_and_created_at"
      t.index ["organization_id", "change_xid", "change_seq"], name: "index_sync_tombstones_on_sync_cursor"
    end

    create_table "tags", force: :cascade do |t|
      t.string "color", default: "#6B7280", null: false
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.bigint "membership_id"
      t.string "name", null: false
      t.bigint "organization_id", null: false
      t.boolean "system", default: false, null: false
      t.bigint "tag_group_id"
      t.datetime "updated_at", null: false
      t.index "organization_id, COALESCE(membership_id, (0)::bigint), name", name: "index_tags_on_org_owner_and_name", unique: true
      t.index ["key"], name: "index_tags_on_key", unique: true
      t.index ["membership_id"], name: "index_tags_on_membership_id", where: "(membership_id IS NOT NULL)"
      t.index ["organization_id"], name: "index_tags_on_organization_id"
    end

    create_table "templates", force: :cascade do |t|
      t.text "body_html"
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.bigint "membership_id"
      t.string "name", null: false
      t.bigint "organization_id", null: false
      t.string "scope", default: "personal", null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_templates_on_key", unique: true
      t.index ["organization_id"], name: "index_templates_on_organization_id"
    end

    create_table "tls_rpt_configs", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.bigint "domain_id", null: false
      t.boolean "enabled", default: false, null: false
      t.string "key", null: false
      t.string "reporting_email", null: false
      t.datetime "updated_at", null: false
      t.index ["domain_id"], name: "index_tls_rpt_configs_on_domain_id", unique: true
      t.index ["key"], name: "index_tls_rpt_configs_on_key", unique: true
    end

    create_table "triage_labels", force: :cascade do |t|
      t.boolean "builtin", default: false, null: false
      t.string "color"
      t.datetime "created_at", null: false
      t.text "description"
      t.boolean "enabled", default: true, null: false
      t.string "key", null: false
      t.string "name", null: false
      t.text "not_for"
      t.bigint "organization_id", null: false
      t.integer "position", default: 0, null: false
      t.string "slug", null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_triage_labels_on_key", unique: true
      t.index ["organization_id", "slug"], name: "index_triage_labels_on_organization_id_and_slug", unique: true
    end

    create_table "user_keys", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.text "encrypted_private_key", null: false
      t.jsonb "kdf_params", default: {}, null: false
      t.string "key", null: false
      t.text "public_key", null: false
      t.text "recovery_encrypted_private_key"
      t.datetime "updated_at", null: false
      t.bigint "user_id", null: false
      t.index ["key"], name: "index_user_keys_on_key", unique: true
      t.index ["user_id"], name: "index_user_keys_on_user_id", unique: true
    end

    create_table "users", force: :cascade do |t|
      t.string "avatar_url"
      t.string "billing_email"
      t.string "billing_email_token_digest"
      t.datetime "billing_email_token_sent_at"
      t.datetime "created_at", null: false
      t.string "default_language", default: "en"
      t.string "default_timezone", default: "UTC"
      t.string "display_name"
      t.string "key", null: false
      t.datetime "last_sign_in_at"
      t.jsonb "lore_auto", default: {}, null: false
      t.datetime "out_of_office_end"
      t.string "out_of_office_message"
      t.datetime "out_of_office_start"
      t.boolean "passkey_required", default: false, null: false
      t.string "password_digest", null: false
      t.string "pending_billing_email"
      t.string "reset_token"
      t.datetime "reset_token_expires_at"
      t.boolean "totp_enabled", default: false, null: false
      t.datetime "totp_last_verified_at"
      t.string "totp_secret"
      t.jsonb "touch_strip", default: {}, null: false
      t.datetime "updated_at", null: false
      t.string "username", null: false
      t.string "webauthn_id"
      t.jsonb "working_hours"
      t.index ["billing_email_token_digest"], name: "index_users_on_billing_email_token_digest", unique: true, where: "(billing_email_token_digest IS NOT NULL)"
      t.index "lower((billing_email)::text)", name: "index_users_on_lower_billing_email", unique: true, where: "(billing_email IS NOT NULL)"
      t.index ["key"], name: "index_users_on_key", unique: true
      t.index ["last_sign_in_at", "id"], name: "index_users_on_last_sign_in_at_and_id", order: { last_sign_in_at: "DESC NULLS LAST", id: :desc }
      t.index ["reset_token"], name: "index_users_on_reset_token", unique: true
      t.index ["username"], name: "index_users_on_username", unique: true
    end

    create_table "views", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.jsonb "filters", default: [], null: false
      t.string "icon"
      t.string "key", null: false
      t.string "kind", default: "personal", null: false
      t.bigint "membership_id"
      t.string "name", null: false
      t.bigint "organization_id", null: false
      t.integer "position", default: 0, null: false
      t.datetime "updated_at", null: false
      t.index ["key"], name: "index_views_on_key", unique: true
      t.index ["membership_id"], name: "index_views_on_membership_id"
      t.index ["organization_id", "kind"], name: "index_views_on_organization_id_and_kind"
      t.index ["organization_id"], name: "index_views_on_organization_id"
    end

    create_table "waitlist_signups", force: :cascade do |t|
      t.string "company"
      t.datetime "created_at", null: false
      t.string "email", null: false
      t.jsonb "email_services", default: {}, null: false
      t.string "industry"
      t.text "industry_note"
      t.string "invite_token"
      t.datetime "invited_at"
      t.string "invited_by"
      t.string "key", null: false
      t.string "name", null: false
      t.datetime "registered_at"
      t.jsonb "social_accounts", default: {}, null: false
      t.string "status", default: "pending", null: false
      t.datetime "updated_at", null: false
      t.bigint "user_id"
      t.index ["email"], name: "index_waitlist_signups_on_email", unique: true
      t.index ["invite_token"], name: "index_waitlist_signups_on_invite_token", unique: true
      t.index ["key"], name: "index_waitlist_signups_on_key", unique: true
      t.index ["status"], name: "index_waitlist_signups_on_status"
      t.index ["user_id"], name: "index_waitlist_signups_on_user_id"
    end

    create_table "webauthn_credentials", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.string "external_id", null: false
      t.string "nickname"
      t.string "public_key", null: false
      t.bigint "sign_count", default: 0, null: false
      t.datetime "updated_at", null: false
      t.bigint "user_id", null: false
      t.index ["external_id"], name: "index_webauthn_credentials_on_external_id", unique: true
      t.index ["user_id"], name: "index_webauthn_credentials_on_user_id"
    end

    create_table "webhooks", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.boolean "enabled", default: true, null: false
      t.jsonb "events", default: []
      t.string "key", null: false
      t.bigint "organization_id", null: false
      t.jsonb "payload_template", default: {}
      t.string "secret"
      t.datetime "updated_at", null: false
      t.string "url", null: false
      t.index ["key"], name: "index_webhooks_on_key", unique: true
      t.index ["organization_id"], name: "index_webhooks_on_organization_id"
    end

    create_table "widget_configs", force: :cascade do |t|
      t.text "allowed_domains"
      t.jsonb "appearance", default: {}
      t.jsonb "behavior", default: {}
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.string "name", null: false
      t.bigint "organization_id", null: false
      t.string "status", default: "active", null: false
      t.datetime "updated_at", null: false
      t.string "widget_token", null: false
      t.index ["key"], name: "index_widget_configs_on_key", unique: true
      t.index ["organization_id"], name: "index_widget_configs_on_organization_id"
      t.index ["widget_token"], name: "index_widget_configs_on_widget_token", unique: true
    end

    create_table "zone_categories", force: :cascade do |t|
      t.string "color", null: false
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.string "name", null: false
      t.integer "position", default: 0, null: false
      t.datetime "updated_at", null: false
      t.bigint "user_id", null: false
      t.index ["key"], name: "index_zone_categories_on_key", unique: true
      t.index ["user_id", "position"], name: "index_zone_categories_on_user_position"
    end

    create_table "zone_dismissals", force: :cascade do |t|
      t.datetime "created_at", null: false
      t.datetime "end_at", null: false
      t.string "occurrence_id", null: false
      t.datetime "updated_at", null: false
      t.bigint "user_id", null: false
      t.index ["user_id", "end_at"], name: "index_zone_dismissals_on_user_end"
      t.index ["user_id", "occurrence_id"], name: "index_zone_dismissals_on_user_occurrence", unique: true
    end

    create_table "zones", force: :cascade do |t|
      t.string "anchor_event_id"
      t.integer "anchor_minutes"
      t.boolean "blocks", default: false, null: false
      t.datetime "created_at", null: false
      t.datetime "end_at", null: false
      t.string "key", null: false
      t.string "name", null: false
      t.text "note"
      t.boolean "notify", default: true, null: false
      t.string "repeat", default: "none", null: false
      t.date "repeat_until"
      t.date "skip_dates", default: [], null: false, array: true
      t.datetime "start_at", null: false
      t.string "time_zone"
      t.datetime "updated_at", null: false
      t.bigint "user_id", null: false
      t.bigint "zone_category_id"
      t.index ["key"], name: "index_zones_on_key", unique: true
      t.index ["user_id", "start_at"], name: "index_zones_on_user_start"
      t.index ["zone_category_id"], name: "index_zones_on_zone_category_id"
    end

    add_foreign_key "activity_events", "conversations"
    add_foreign_key "activity_events", "memberships"
    add_foreign_key "activity_events", "organizations"
    add_foreign_key "agencies", "users", column: "owner_id"
    add_foreign_key "agent_run_logs", "agents"
    add_foreign_key "agent_run_logs", "conversations"
    add_foreign_key "agents", "memberships"
    add_foreign_key "agents", "memberships", column: "supervisor_membership_id"
    add_foreign_key "agents", "organizations"
    add_foreign_key "ai_triage_usages", "organizations"
    add_foreign_key "api_keys", "users"
    add_foreign_key "attachments", "messages"
    add_foreign_key "attachments", "organizations"
    add_foreign_key "audit_logs", "memberships"
    add_foreign_key "audit_logs", "organizations"
    add_foreign_key "blocked_times", "memberships"
    add_foreign_key "blocked_times", "organizations"
    add_foreign_key "calendar_attendees", "calendar_events"
    add_foreign_key "calendar_events", "calendars"
    add_foreign_key "calendar_events", "memberships", column: "created_by_membership_id"
    add_foreign_key "calendar_events", "organizations"
    add_foreign_key "calendar_reminders", "calendar_events"
    add_foreign_key "calendars", "memberships"
    add_foreign_key "calendars", "organizations"
    add_foreign_key "conferencing_connections", "memberships"
    add_foreign_key "contacts", "organizations"
    add_foreign_key "conversation_accesses", "conversations"
    add_foreign_key "conversation_accesses", "memberships"
    add_foreign_key "conversation_assignees", "conversations"
    add_foreign_key "conversation_assignees", "memberships"
    add_foreign_key "conversation_tags", "conversations"
    add_foreign_key "conversation_tags", "tags"
    add_foreign_key "conversations", "memberships", column: "owner_membership_id", on_delete: :cascade
    add_foreign_key "conversations", "memberships", column: "personal_membership_id", on_delete: :nullify
    add_foreign_key "conversations", "organizations"
    add_foreign_key "custom_roles", "organizations"
    add_foreign_key "custom_statuses", "organizations"
    add_foreign_key "data_exports", "memberships", column: "requested_by_membership_id", on_delete: :nullify
    add_foreign_key "data_exports", "organizations"
    add_foreign_key "delivery_attempts", "delivery_channels"
    add_foreign_key "delivery_attempts", "delivery_statuses"
    add_foreign_key "delivery_channels", "organizations"
    add_foreign_key "delivery_statuses", "delivery_channels"
    add_foreign_key "delivery_statuses", "messages"
    add_foreign_key "disk_agent_grants", "agents", on_delete: :cascade
    add_foreign_key "disk_agent_grants", "disk_nodes", column: "node_id", on_delete: :cascade
    add_foreign_key "disk_agent_grants", "memberships", column: "granted_by_membership_id", on_delete: :nullify
    add_foreign_key "disk_agent_grants", "organizations"
    add_foreign_key "disk_events", "agents", column: "actor_agent_id", on_delete: :nullify
    add_foreign_key "disk_events", "disk_links", column: "link_id", on_delete: :nullify
    add_foreign_key "disk_events", "disk_nodes", column: "node_id", on_delete: :nullify
    add_foreign_key "disk_events", "disk_shares", column: "share_id", on_delete: :nullify
    add_foreign_key "disk_events", "memberships", column: "actor_membership_id", on_delete: :nullify
    add_foreign_key "disk_events", "organizations"
    add_foreign_key "disk_grants", "disk_nodes", column: "node_id", on_delete: :cascade
    add_foreign_key "disk_grants", "memberships", column: "granted_by_membership_id", on_delete: :nullify
    add_foreign_key "disk_grants", "memberships", on_delete: :cascade
    add_foreign_key "disk_grants", "organizations"
    add_foreign_key "disk_import_connections", "memberships", on_delete: :cascade
    add_foreign_key "disk_import_connections", "organizations"
    add_foreign_key "disk_import_items", "disk_imports", column: "import_id", on_delete: :cascade
    add_foreign_key "disk_import_items", "disk_nodes", column: "node_id", on_delete: :nullify
    add_foreign_key "disk_import_items", "disk_nodes", column: "target_node_id", on_delete: :cascade
    add_foreign_key "disk_import_items", "organizations"
    add_foreign_key "disk_imports", "disk_import_connections", column: "connection_id", on_delete: :nullify
    add_foreign_key "disk_imports", "disk_nodes", column: "target_node_id", on_delete: :nullify
    add_foreign_key "disk_imports", "disk_shares", column: "share_id", on_delete: :nullify
    add_foreign_key "disk_imports", "memberships", column: "owner_membership_id", on_delete: :nullify
    add_foreign_key "disk_imports", "memberships", on_delete: :cascade
    add_foreign_key "disk_imports", "organizations"
    add_foreign_key "disk_key_grants", "disk_nodes", column: "scope_node_id", on_delete: :cascade
    add_foreign_key "disk_key_grants", "memberships"
    add_foreign_key "disk_key_grants", "memberships", column: "granted_by_membership_id", on_delete: :nullify
    add_foreign_key "disk_key_grants", "organizations"
    add_foreign_key "disk_links", "disk_nodes", column: "node_id", on_delete: :cascade
    add_foreign_key "disk_links", "disk_versions", column: "version_id", on_delete: :cascade
    add_foreign_key "disk_links", "memberships", column: "created_by_membership_id", on_delete: :nullify
    add_foreign_key "disk_links", "organizations"
    add_foreign_key "disk_nodes", "disk_nodes", column: "original_parent_id", on_delete: :nullify
    add_foreign_key "disk_nodes", "disk_nodes", column: "parent_id"
    add_foreign_key "disk_nodes", "disk_nodes", column: "seal_scope_node_id"
    add_foreign_key "disk_nodes", "disk_shares", column: "share_id"
    add_foreign_key "disk_nodes", "disk_versions", column: "current_version_id"
    add_foreign_key "disk_nodes", "memberships", column: "created_by_membership_id", on_delete: :nullify
    add_foreign_key "disk_nodes", "memberships", column: "custodian_membership_id"
    add_foreign_key "disk_nodes", "memberships", column: "listing_signer_membership_id", on_delete: :nullify
    add_foreign_key "disk_nodes", "memberships", column: "modified_by_membership_id", on_delete: :nullify
    add_foreign_key "disk_nodes", "memberships", column: "trashed_by_membership_id", on_delete: :nullify
    add_foreign_key "disk_nodes", "organizations"
    add_foreign_key "disk_page_updates", "disk_nodes", column: "node_id", on_delete: :cascade
    add_foreign_key "disk_page_updates", "organizations"
    add_foreign_key "disk_page_versions", "disk_nodes", column: "node_id", on_delete: :cascade
    add_foreign_key "disk_page_versions", "memberships", column: "author_membership_id", on_delete: :nullify
    add_foreign_key "disk_page_versions", "organizations"
    add_foreign_key "disk_pages", "disk_nodes", column: "node_id", on_delete: :cascade
    add_foreign_key "disk_pages", "organizations"
    add_foreign_key "disk_recents", "disk_nodes", column: "node_id", on_delete: :cascade
    add_foreign_key "disk_recents", "memberships", on_delete: :cascade
    add_foreign_key "disk_recents", "organizations"
    add_foreign_key "disk_scope_epochs", "disk_nodes", column: "scope_node_id", on_delete: :cascade
    add_foreign_key "disk_scope_epochs", "memberships", column: "created_by_membership_id", on_delete: :nullify
    add_foreign_key "disk_scope_epochs", "organizations"
    add_foreign_key "disk_share_memberships", "disk_shares", column: "share_id", on_delete: :cascade
    add_foreign_key "disk_share_memberships", "memberships", on_delete: :cascade
    add_foreign_key "disk_share_memberships", "organizations"
    add_foreign_key "disk_shares", "disk_nodes", column: "root_node_id", on_delete: :nullify
    add_foreign_key "disk_shares", "domains", on_delete: :nullify
    add_foreign_key "disk_shares", "memberships", column: "trashed_by_membership_id", on_delete: :nullify
    add_foreign_key "disk_shares", "organizations"
    add_foreign_key "disk_stars", "disk_nodes", column: "node_id", on_delete: :cascade
    add_foreign_key "disk_stars", "memberships", on_delete: :cascade
    add_foreign_key "disk_stars", "organizations"
    add_foreign_key "disk_upload_parts", "disk_uploads", column: "upload_id", on_delete: :cascade
    add_foreign_key "disk_upload_parts", "organizations"
    add_foreign_key "disk_uploads", "disk_nodes", column: "node_id", on_delete: :nullify
    add_foreign_key "disk_uploads", "disk_nodes", column: "parent_id", on_delete: :nullify
    add_foreign_key "disk_uploads", "memberships", on_delete: :cascade
    add_foreign_key "disk_uploads", "organizations"
    add_foreign_key "disk_versions", "disk_nodes", column: "node_id", on_delete: :cascade
    add_foreign_key "disk_versions", "memberships", column: "author_membership_id", on_delete: :nullify
    add_foreign_key "disk_versions", "organizations"
    add_foreign_key "domains", "organizations"
    add_foreign_key "esp_deliveries", "esp_messages", on_delete: :cascade
    add_foreign_key "esp_deliveries", "organizations", on_delete: :cascade
    add_foreign_key "esp_domains", "organizations", on_delete: :cascade
    add_foreign_key "esp_events", "esp_deliveries", on_delete: :cascade
    add_foreign_key "esp_events", "esp_messages", on_delete: :cascade
    add_foreign_key "esp_events", "organizations", on_delete: :cascade
    add_foreign_key "esp_keys", "organizations", on_delete: :cascade
    add_foreign_key "esp_keys", "users", column: "created_by_id", on_delete: :nullify
    add_foreign_key "esp_messages", "esp_keys"
    add_foreign_key "esp_messages", "organizations", on_delete: :cascade
    add_foreign_key "external_busy_blocks", "memberships"
    add_foreign_key "external_busy_blocks", "organizations"
    add_foreign_key "imap_folders", "memberships", on_delete: :cascade
    add_foreign_key "imap_messages", "memberships", on_delete: :cascade
    add_foreign_key "imap_messages", "messages", on_delete: :cascade
    add_foreign_key "integrations", "organizations"
    add_foreign_key "lore_entities", "domains", on_delete: :cascade
    add_foreign_key "lore_entities", "lore_entities", column: "merged_into_id", on_delete: :nullify
    add_foreign_key "lore_entities", "organizations", on_delete: :cascade
    add_foreign_key "lore_facts", "conversations", on_delete: :cascade
    add_foreign_key "lore_facts", "lore_entities", column: "related_entity_id", on_delete: :cascade
    add_foreign_key "lore_facts", "lore_entities", on_delete: :cascade
    add_foreign_key "lore_facts", "messages", on_delete: :nullify
    add_foreign_key "lore_member_dones", "conversations", on_delete: :cascade
    add_foreign_key "lore_member_dones", "memberships", on_delete: :cascade
    add_foreign_key "lore_mentions", "conversations", on_delete: :cascade
    add_foreign_key "lore_mentions", "lore_entities", on_delete: :cascade
    add_foreign_key "mail_client_passwords", "memberships", on_delete: :cascade
    add_foreign_key "mail_filters", "organizations"
    add_foreign_key "mail_import_threads", "conversations", on_delete: :cascade
    add_foreign_key "mail_import_threads", "mail_imports", on_delete: :cascade
    add_foreign_key "mail_imports", "disk_import_connections", column: "connection_id", on_delete: :nullify
    add_foreign_key "mail_imports", "disk_nodes", column: "source_node_id", on_delete: :nullify
    add_foreign_key "mail_imports", "domains", on_delete: :cascade
    add_foreign_key "mail_imports", "memberships", column: "owner_membership_id", on_delete: :cascade
    add_foreign_key "mail_imports", "memberships", on_delete: :cascade
    add_foreign_key "mail_imports", "organizations"
    add_foreign_key "mailbox_aliases", "domains"
    add_foreign_key "mailbox_aliases", "memberships", column: "target_membership_id"
    add_foreign_key "mailbox_aliases", "organizations"
    add_foreign_key "mailbox_graph_snapshots", "organizations"
    add_foreign_key "mailboxes", "domains"
    add_foreign_key "mailboxes", "memberships"
    add_foreign_key "meet_links", "memberships"
    add_foreign_key "meet_links", "memberships", column: "invitee_membership_id"
    add_foreign_key "meet_links", "organizations"
    add_foreign_key "meeting_requests", "calendar_events"
    add_foreign_key "meeting_requests", "meet_links"
    add_foreign_key "meeting_requests", "messages"
    add_foreign_key "meeting_requests", "organizations"
    add_foreign_key "member_groups", "organizations"
    add_foreign_key "memberships", "organizations"
    add_foreign_key "memberships", "users"
    add_foreign_key "messages", "conversations"
    add_foreign_key "messages", "memberships", column: "owner_membership_id", on_delete: :cascade
    add_foreign_key "messages", "organizations"
    add_foreign_key "mta_sts_policies", "domains"
    add_foreign_key "note_reactions", "memberships"
    add_foreign_key "note_reactions", "notes"
    add_foreign_key "notes", "conversations"
    add_foreign_key "notes", "memberships"
    add_foreign_key "notes", "notes", column: "parent_note_id"
    add_foreign_key "notes", "organizations"
    add_foreign_key "notifications", "conversations"
    add_foreign_key "notifications", "memberships", column: "actor_membership_id"
    add_foreign_key "notifications", "organizations"
    add_foreign_key "notifications", "users"
    add_foreign_key "oauth_identities", "users"
    add_foreign_key "oauth_apps", "organizations"
    add_foreign_key "oauth_apps", "users", column: "created_by_id"
    add_foreign_key "oauth_grants", "oauth_apps"
    add_foreign_key "organizations", "agencies"
    add_foreign_key "organizations", "plans"
    add_foreign_key "organizations", "users", column: "owner_id"
    add_foreign_key "organizations", "users", column: "personal_user_id", on_delete: :cascade
    add_foreign_key "out_of_office_replies", "organizations"
    add_foreign_key "out_of_office_replies", "users"
    add_foreign_key "push_devices", "users", name: "push_devices_user_id_fkey"
    add_foreign_key "push_subscriptions", "users"
    add_foreign_key "rule_logs", "conversations"
    add_foreign_key "rule_logs", "rules"
    add_foreign_key "rules", "organizations"
    add_foreign_key "saas_audit_logs", "admin_credentials"
    add_foreign_key "saml_configs", "organizations"
    add_foreign_key "saml_identities", "organizations", on_delete: :cascade
    add_foreign_key "saml_identities", "users", on_delete: :cascade
    add_foreign_key "sessions", "users"
    add_foreign_key "signatures", "memberships"
    add_foreign_key "signatures", "organizations"
    add_foreign_key "subscriptions", "organizations"
    add_foreign_key "subscriptions", "plans"
    add_foreign_key "tag_groups", "organizations"
    add_foreign_key "tags", "memberships", on_delete: :cascade
    add_foreign_key "tags", "organizations"
    add_foreign_key "templates", "memberships"
    add_foreign_key "templates", "organizations"
    add_foreign_key "tls_rpt_configs", "domains"
    add_foreign_key "triage_labels", "organizations", on_delete: :cascade
    add_foreign_key "views", "memberships"
    add_foreign_key "views", "organizations"
    add_foreign_key "webauthn_credentials", "users"
    add_foreign_key "webhooks", "organizations"
    add_foreign_key "widget_configs", "organizations"
    add_foreign_key "zone_categories", "users"
    add_foreign_key "zone_dismissals", "users"
    add_foreign_key "zones", "users"
    add_foreign_key "zones", "zone_categories", on_delete: :nullify
  end
end
