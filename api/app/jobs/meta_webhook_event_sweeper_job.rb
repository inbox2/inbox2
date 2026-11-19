# GCs the ephemeral Meta webhook payload buffer. Events are short-lived (MetaWebhookEvent::TTL):
# the device fetches + acks within seconds, but a TTL grace covers a user's multiple devices
# and offline catch-up. This deletes anything past the TTL (consumed or not) so message
# content doesn't linger in the cloud. Scheduled frequently via config/recurring.yml.
class MetaWebhookEventSweeperJob < ApplicationJob
  queue_as :default

  def perform
    count = MetaWebhookEvent.expired.delete_all
    Rails.logger.info("[MetaWebhookEventSweeperJob] purged #{count} expired buffered event(s)") if count.positive?
    count
  end
end
