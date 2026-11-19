# Code audit 2026-10-18 (TODO 47.9): indexes for the predicates the hot reads
# actually use. CONCURRENTLY so a later, bigger prod table never blocks writes
# while db:prepare runs on pod boot (hence disable_ddl_transaction!).
class AddHotPathIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    # Unread badge (conversations#unread_count), the Spaces board's four GROUP BYs,
    # and the per-device badge push all count open+unread by org/domain/space.
    add_index :conversations, %i[organization_id domain_id space_id],
              where: "status = 'open' AND read = false",
              name: "index_conversations_on_open_unread",
              algorithm: :concurrently, if_not_exists: true
    # CalendarEvent.visible_to matches attendees case-insensitively.
    add_index :calendar_attendees, "LOWER(email)",
              name: "index_calendar_attendees_on_lower_email",
              algorithm: :concurrently, if_not_exists: true
    # Delivery log + per-channel status rollups.
    add_index :delivery_statuses, %i[delivery_channel_id status],
              name: "index_delivery_statuses_on_channel_and_status",
              algorithm: :concurrently, if_not_exists: true
    add_index :delivery_statuses, :created_at,
              name: "index_delivery_statuses_on_created_at",
              algorithm: :concurrently, if_not_exists: true
    # Disk listings filter by org before anything else.
    add_index :disk_events, :organization_id,
              name: "index_disk_events_on_organization_id",
              algorithm: :concurrently, if_not_exists: true
    add_index :disk_links, :organization_id,
              name: "index_disk_links_on_organization_id",
              algorithm: :concurrently, if_not_exists: true
  end
end
