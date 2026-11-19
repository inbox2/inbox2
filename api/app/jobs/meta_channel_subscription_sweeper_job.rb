# Reclaims abandoned Meta channel registrations. Any active row whose 30-day lease has
# lapsed (the device hasn't re-reported in a month — see MetaChannelSubscription::LEASE_DURATION
# and the device's renew_meta_push_due) is marked expired so the webhook receiver stops
# routing to ghosts. Reconnecting re-registers fresh. Scheduled daily via config/recurring.yml.
class MetaChannelSubscriptionSweeperJob < ApplicationJob
  queue_as :default

  def perform
    count = MetaChannelSubscription.lease_expired.update_all(
      status: MetaChannelSubscription::STATUS_EXPIRED,
      updated_at: Time.current
    )
    Rails.logger.info("[MetaChannelSubscriptionSweeperJob] expired #{count} lapsed registration(s)") if count.positive?
    count
  end
end
