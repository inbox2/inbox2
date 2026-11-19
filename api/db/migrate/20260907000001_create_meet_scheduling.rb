# Public meeting scheduler ("meet links", docs/Feature-Spec.md): a per-member
# shareable link that shows busy/free only, takes meeting *requests* from
# visitors, and books nothing until the invitee accepts.
#
#   meet_links               — the shareable links (creator ≠ invitee allowed:
#                              a link can book a colleague).
#   blocked_times            — "not available" windows; feed free/busy as busy
#                              but are deliberately NOT calendar events.
#   meeting_requests         — a visitor's pending/accepted/declined ask.
#   conferencing_connections — per-member Google/Microsoft OAuth for generating
#                              Meet/Teams links at accept time.
#
# `messages.meeting_request` mirrors `calendar_invite`: the banner payload lives
# on the inbox message row, so MessageSerializer needs no extra query.
#
# Its own file so production actually migrates (prod already recorded
# 20260522000001). Everything is ALSO in the initial schema for fresh installs;
# `if_not_exists` makes this a no-op there.
class CreateMeetScheduling < ActiveRecord::Migration[8.1]
  def change
    create_table :meet_links, if_not_exists: true do |t|
      t.string :key, null: false
      t.bigint :organization_id, null: false
      # Who created (and manages) the link.
      t.bigint :membership_id, null: false
      # Who gets booked. Defaults to the creator; a colleague link points here.
      t.bigint :invitee_membership_id, null: false
      # The URL capability. Unguessable and revocable; separate from `key` so a
      # leaked public id never doubles as a booking capability.
      t.string :token, null: false
      t.string :label, null: false
      t.integer :duration_minutes, null: false, default: 30
      t.integer :min_notice_minutes, null: false, default: 240
      t.integer :max_ahead_days, null: false, default: 28
      t.string :conference_mode, null: false, default: "none"
      t.datetime :revoked_at
      t.integer :visits_count, null: false, default: 0
      t.integer :requests_count, null: false, default: 0
      t.timestamps
      t.index :key, unique: true
      t.index :token, unique: true
      t.index %i[organization_id membership_id]
    end

    create_table :blocked_times, if_not_exists: true do |t|
      t.string :key, null: false
      t.bigint :organization_id, null: false
      t.bigint :membership_id, null: false
      t.datetime :start_at, null: false
      t.datetime :end_at, null: false
      t.timestamps
      t.index :key, unique: true
      t.index %i[organization_id membership_id start_at], name: "index_blocked_times_on_org_membership_start"
    end

    create_table :meeting_requests, if_not_exists: true do |t|
      t.string :key, null: false
      t.bigint :organization_id, null: false
      t.bigint :meet_link_id, null: false
      t.string :name, null: false
      t.string :email, null: false
      t.text :note
      t.datetime :start_at, null: false
      t.datetime :end_at, null: false
      t.string :visitor_timezone
      t.string :status, null: false, default: "pending"
      t.text :decline_reason
      # The inbox message carrying the request banner, and the event accept created.
      t.bigint :message_id
      t.bigint :calendar_event_id
      t.timestamps
      t.index :key, unique: true
      t.index %i[meet_link_id status]
      t.index :organization_id
    end

    create_table :conferencing_connections, if_not_exists: true do |t|
      t.string :key, null: false
      t.bigint :membership_id, null: false
      t.string :provider, null: false
      t.string :account_email
      # Rails-encrypted (ActiveRecord::Encryption); read only at accept time.
      t.text :refresh_token, null: false
      t.timestamps
      t.index :key, unique: true
      t.index %i[membership_id provider], unique: true
    end

    add_column :messages, :meeting_request, :jsonb, if_not_exists: true

    add_foreign_key :meet_links, :organizations, if_not_exists: true
    add_foreign_key :meet_links, :memberships, if_not_exists: true
    add_foreign_key :meet_links, :memberships, column: :invitee_membership_id, if_not_exists: true
    add_foreign_key :blocked_times, :organizations, if_not_exists: true
    add_foreign_key :blocked_times, :memberships, if_not_exists: true
    add_foreign_key :meeting_requests, :organizations, if_not_exists: true
    add_foreign_key :meeting_requests, :meet_links, if_not_exists: true
    add_foreign_key :meeting_requests, :messages, if_not_exists: true
    add_foreign_key :meeting_requests, :calendar_events, if_not_exists: true
    add_foreign_key :conferencing_connections, :memberships, if_not_exists: true
  end
end
