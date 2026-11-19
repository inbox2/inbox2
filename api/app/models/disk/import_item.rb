module Disk
  # One source item in one target. Unique per (org, provider, target,
  # source id), so a re-run finds it and updates its node. import_id moves to
  # the latest run that touched it; that run's report lists it.
  class ImportItem < ApplicationRecord
    STATUS_DONE = "done".freeze
    STATUS_SKIPPED = "skipped".freeze
    STATUS_FAILED = "failed".freeze
    STATUSES = [STATUS_DONE, STATUS_SKIPPED, STATUS_FAILED].freeze

    belongs_to :organization
    belongs_to :import, class_name: "Disk::Import"
    belongs_to :node, class_name: "Disk::Node", optional: true

    validates :status, inclusion: { in: STATUSES }

    def live_node
      node unless node.nil? || node.trashed?
    end
  end
end
