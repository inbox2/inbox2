# A busy period one of the member's devices read off a local (Gmail/Office365)
# calendar (docs/Calendar.md "External busy"). Bare start/end only — no title,
# no attendees — and never exposed as an object: it exists to make FreeBusy
# answer "busy" for meetings the server never syncs.
#
# `source` is the uploading device; each device replaces only its own set, so
# a phone with fewer accounts never wipes what the desktop reported.
class ExternalBusyBlock < ApplicationRecord
  # Horizon a device may report, and the most blocks one upload may carry.
  MAX_RANGE_DAYS = 120
  MAX_BLOCKS = 3000
  # A device that stopped reporting (uninstalled, signed out) — its blocks go.
  STALE_AFTER = 30.days

  belongs_to :organization
  belongs_to :membership

  scope :in_range, ->(range_start, range_end) {
    where("start_at < ? AND end_at > ?", range_end, range_start)
  }
  # Reads ignore a source that went quiet, even if the member never uploads
  # again to trigger the delete in replace!.
  # ponytail: stale rows stay in the table until that member's next upload;
  # add a periodic purge if the table ever grows enough to matter.
  scope :live, -> { where(updated_at: STALE_AFTER.ago..) }

  # Replace everything `source` reported for this member with `periods`
  # ([[start, end], ...]), and drop sources that went quiet.
  def self.replace!(membership:, organization:, source:, periods:)
    now = Time.current
    transaction do
      # Serialize uploads per member: two concurrent replaces would otherwise
      # both delete before either inserts, leaving both snapshots behind.
      membership.lock!
      where(membership: membership, source: source).delete_all
      where(membership: membership).where(updated_at: ...(now - STALE_AFTER)).delete_all
      rows = periods.map do |from, to|
        { organization_id: organization.id, membership_id: membership.id, source: source,
          start_at: from, end_at: to, created_at: now, updated_at: now }
      end
      insert_all!(rows) if rows.any?
    end
  end
end
