# Fans a content-free "go sync this mailbox" signal out to all of a user's connected
# clients over ActionCable (PushSyncChannel). The payload NEVER contains message content —
# only an indication, so the client pulls via its own (client-side) token. See docs/Cloud-Push.md.
class ChannelPushBroadcaster
  def self.call(subscription, history_id: nil)
    return unless subscription&.live?

    subscription.update_column(:last_notification_at, Time.current)

    ActionCable.server.broadcast(
      "push_sync_#{subscription.user.key}",
      {
        type: "channel_sync",
        provider: subscription.provider,
        email: subscription.external_email,
        history_id: history_id
      }.compact
    )

    # Same content-free signal as a silent mobile push: wakes the iOS/Android
    # app to run its own sync (the app posts the visible notification locally).
    MobilePushSender.channel_sync(
      subscription.user,
      provider: subscription.provider,
      email: subscription.external_email,
      history_id: history_id
    )
  rescue => e
    Rails.logger.warn("[ChannelPushBroadcaster] broadcast error: #{e.message}")
  end
end
