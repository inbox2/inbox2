class SyncTombstonePruneJob < ApplicationJob
  queue_as :default

  def perform
    SyncTombstone.prune!
  end
end
