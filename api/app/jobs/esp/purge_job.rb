# Drops stored messages older than Esp::BODY_RETENTION. The log rows stay.
class Esp::PurgeJob < ApplicationJob
  queue_as :default

  def perform
    Esp::Message.where(created_at: ...Esp::BODY_RETENTION.ago).where.not(raw_mime: nil).update_all(raw_mime: nil)
  end
end
