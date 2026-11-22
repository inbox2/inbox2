class SyncTombstonePruneJob < ApplicationJob
  queue_as :default

  def perform
    SyncTombstone.prune!
    Disk::SyncEvent.prune!
  end
end
