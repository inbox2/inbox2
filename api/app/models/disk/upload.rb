module Disk
  # A reserved upload (docs/plans/disk-build.md section 8). node_key and
  # version_key are the public ids the new node and version will get, handed
  # out at reserve time so a sealed client can bind its chunks to them.
  class Upload < ApplicationRecord
    key_prefix "dup"

    STATE_RESERVED = "reserved".freeze
    STATE_COMPLETING = "completing".freeze
    STATE_DONE = "done".freeze
    STATE_ABORTED = "aborted".freeze
    STATES = [STATE_RESERVED, STATE_COMPLETING, STATE_DONE, STATE_ABORTED].freeze
    ACTIVE_STATES = [STATE_RESERVED, STATE_COMPLETING].freeze
    # The code on a 409 for parts or completion of an upload no longer reserved.
    CLOSED = "upload_closed".freeze

    # Every part URL lasts minutes, so a live upload keeps asking for more and
    # each ask pushes this out; an abandoned one is released within a day (spec F2).
    TTL = 12.hours
    MIN_PART_BYTES = 8.megabytes # S3 wants 5 MiB or more for every part but the last
    MAX_PARTS = 10_000
    PARTS_PER_CALL = 100
    CHUNK_SIZES = [1.megabyte, 4.megabytes].freeze # sealed chunking (build guide section 1)

    belongs_to :organization
    belongs_to :membership
    belongs_to :parent, class_name: "Disk::Node", optional: true
    belongs_to :node, class_name: "Disk::Node", optional: true
    has_many :parts, class_name: "Disk::UploadPart", dependent: :delete_all

    validates :state, inclusion: { in: STATES }
    validates :declared_bytes, numericality: { greater_than_or_equal_to: 0 }

    scope :active, -> { where(state: ACTIVE_STATES) }

    def reserved? = state == STATE_RESERVED
    def completing? = state == STATE_COMPLETING
    def done? = state == STATE_DONE
    def aborted? = state == STATE_ABORTED
    def active? = ACTIVE_STATES.include?(state)

    # Whole MiB, at least MIN_PART_BYTES, and few enough parts for S3's limit.
    def self.part_bytes_for(size)
      mib = 1.megabyte
      [MIN_PART_BYTES, ((size.to_f / MAX_PARTS) / mib).ceil * mib].max
    end

    def part_count = (declared_bytes.to_f / part_bytes).ceil
    def version = Disk::Version.find_by(key: version_key)
  end
end
