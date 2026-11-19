# Reclaims abandoned cloud-push subscriptions (§1a in docs/Cloud-Push.md).
#
# Provider subscriptions (Gmail watch ~7d, Graph ~3d) already lapse on their own when a
# client stops renewing. This sweep is the Rails-side hygiene: any active row whose 30-day
# lease has expired (the user hasn't opened the channel in a month) is marked expired so the
# broadcaster and webhook receivers stop fanning out to ghosts. Coming back re-registers fresh.
#
# Scheduled daily via config/recurring.yml.
class ChannelPushSubscriptionSweeperJob < ApplicationJob
  queue_as :default

  def perform
    count = ChannelPushSubscription.lease_expired.update_all(
      status: ChannelPushSubscription::STATUS_EXPIRED,
      updated_at: Time.current
    )
    Rails.logger.info("[ChannelPushSubscriptionSweeperJob] expired #{count} lapsed subscription(s)") if count.positive?
    count
  end
end
