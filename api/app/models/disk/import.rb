module Disk
  # One import run: one source space into one target folder or share (spec
  # F10). The cursor is the adapter's checkpoint while running and its change
  # token once done, so the next run of the same space picks up only changes.
  class Import < ApplicationRecord
    key_prefix "dim"

    STATE_QUEUED = "queued".freeze
    STATE_RUNNING = "running".freeze
    STATE_PAUSED = "paused".freeze
    STATE_DONE = "done".freeze
    STATE_CANCELLED = "cancelled".freeze
    STATE_SKIPPED = "skipped".freeze # a source user with no matching member: listed, not imported
    STATES = [STATE_QUEUED, STATE_RUNNING, STATE_PAUSED, STATE_DONE, STATE_CANCELLED, STATE_SKIPPED].freeze
    ACTIVE_STATES = [STATE_QUEUED, STATE_RUNNING].freeze

    # Why a paused import stopped. Each is resumable.
    PAUSE_QUOTA = "quota".freeze
    PAUSE_TRANSFER_CAP = "transfer_cap".freeze
    PAUSE_AUTHORIZATION = "authorization".freeze
    PAUSE_ERROR = "error".freeze
    PAUSE_REASONS = [PAUSE_QUOTA, PAUSE_TRANSFER_CAP, PAUSE_AUTHORIZATION, PAUSE_ERROR].freeze

    SPACE_PERSONAL = "personal".freeze # the member's own drive into their C:\
    SPACE_SHARED = "shared".freeze     # a shared drive, library or team folder into a D:\ share
    SPACE_MEMBER = "member".freeze     # another member's drive into that member's C:\ (admin)
    SPACE_KINDS = [SPACE_PERSONAL, SPACE_SHARED, SPACE_MEMBER].freeze

    # A running import whose job has not checkpointed for this long is taken
    # to have died with its worker and may be resumed.
    STALE_AFTER = 15.minutes

    belongs_to :organization
    belongs_to :membership
    belongs_to :owner, class_name: "Membership", foreign_key: :owner_membership_id, optional: true
    belongs_to :connection, class_name: "Disk::ImportConnection", optional: true
    belongs_to :target_node, class_name: "Disk::Node", optional: true
    belongs_to :share, class_name: "Disk::Share", optional: true
    has_many :items, class_name: "Disk::ImportItem"

    validates :provider, inclusion: { in: Disk::ImportSource::PROVIDERS }
    validates :state, inclusion: { in: STATES }
    validates :space_kind, inclusion: { in: SPACE_KINDS }
    validates :pause_reason, inclusion: { in: PAUSE_REASONS }, allow_nil: true

    STATES.each { |s| define_method("#{s}?") { state == s } }

    def resumable?
      paused? || queued? || (running? && updated_at < STALE_AFTER.ago)
    end

    # Who the import writes as: the custodian of the C:\ it lands in, or the
    # owner or admin who started a share import.
    def actor = owner || membership
  end
end
