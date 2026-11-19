# Auto-cleanup for the disposable folders: permanently deletes conversations
# that have sat in Trash or Spam longer than Conversation::JUNK_RETENTION
# (30 days). Mirrors the manual "Empty folder" action, on a timer.
#
# `updated_at` is the retention clock: it's stamped when a thread is trashed or
# marked spam, and any later activity (a new reply landing on a spam thread)
# resets it — so a thread is only purged after 30 quiet days in the folder.
#
# Destroy (not delete_all) so dependent messages/tags/notes cascade. Batched to
# keep the transaction footprint small on a large backlog.
#
# Scheduled daily via config/recurring.yml.
class PurgeExpiredJunkJob < ApplicationJob
  queue_as :default

  def perform(retention: Conversation::JUNK_RETENTION)
    cutoff = Time.current - retention
    total = 0
    Conversation
      .where(status: Conversation::EMPTYABLE_STATUSES)
      .where(updated_at: ..cutoff)
      .in_batches(of: 500) do |batch|
        total += batch.destroy_all.size
      end
    Rails.logger.info("[PurgeExpiredJunkJob] purged #{total} expired junk conversation(s)") if total.positive?
    total
  end
end
