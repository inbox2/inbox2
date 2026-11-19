# Recovers ESP deliveries that have no job working on them. Runs every few
# minutes; the claim in Esp::DeliverJob makes a second job harmless.
#   - waiting with no job: the request or the result handler died before enqueueing
#   - claimed but never published: the job died between the two
#   - published with no verdict after the mail queue has dropped the job
class Esp::RequeueJob < ApplicationJob
  queue_as :default

  # Longer than the longest retry backoff, so a scheduled retry is not raced.
  STALE_AFTER = 20.minutes
  # A publish takes seconds; a claim this old has no job behind it.
  ABANDONED_AFTER = 10.minutes
  # OutboundMailPublisher keeps a job for 72 hours.
  UNANSWERED_AFTER = 73.hours

  def perform
    abandoned = Esp::Delivery.abandoned(ABANDONED_AFTER.ago).to_a.each(&:release!).map(&:id)
    waiting = Esp::Delivery.unclaimed.where(updated_at: ...STALE_AFTER.ago).pluck(:id)
    (abandoned | waiting).each { |id| Esp::DeliverJob.perform_later(id) }
    Esp::Delivery.unanswered(UNANSWERED_AFTER.ago).find_each(&:expire!)
  end
end
