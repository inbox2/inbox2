# Serializes a Zone::Occurrence (docs/Calendar.md "Zones"): the series' fields
# with this occurrence's times. `id` is the occurrence id; `series_id` is what
# PATCH/DELETE take (they also accept the occurrence id).
class ZoneSerializer
  include Alba::Resource

  attribute(:id) { |o| o.id }
  attribute(:series_id) { |o| o.zone.key }
  attribute(:name) { |o| o.zone.name }
  attribute(:note) { |o| o.zone.note }
  attribute(:start_at) { |o| o.start_at.utc }
  attribute(:end_at) { |o| o.end_at.utc }
  attribute(:notify) { |o| o.zone.notify }
  attribute(:blocks) { |o| o.zone.blocks }
  attribute(:repeat) { |o| o.zone.repeat }
  attribute(:repeat_until) { |o| o.zone.repeat_until }
  attribute(:time_zone) { |o| o.zone.time_zone }
  attribute(:anchor_event_id) { |o| o.zone.anchor_event_id }
  attribute(:anchor_minutes) { |o| o.zone.anchor_minutes }
  attribute(:category_id) { |o| o.zone.zone_category&.key }
  attribute(:created_at) { |o| o.zone.created_at }

  def self.one(zone)
    new(Zone::Occurrence.new(zone, zone.start_at, zone.end_at)).to_h
  end
end
