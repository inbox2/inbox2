# Fans a Meta-event nudge out to all of a user's connected clients. Unlike the
# content-free Gmail/Office365 channel_sync, the device cannot pull WhatsApp content, so
# the nudge carries the buffer key (`event_key`); the device fetches the raw payload from
# the relay, verifies the HMAC locally, then normalizes. The broadcast itself carries NO
# message content — only the key + object. See docs/Cloud-Push.md (Meta).
class MetaWebhookBroadcaster
  def self.call(event)
    return unless event&.user

    ActionCable.server.broadcast(
      "push_sync_#{event.user.key}",
      {
        type: "meta_event",
        event_key: event.key,
        object: event.object
      }
    )

    # Silent mobile push: wakes the app to fetch + apply the buffered event.
    MobilePushSender.meta_event(event.user, event_key: event.key, object: event.object)
  rescue => e
    Rails.logger.warn("[MetaWebhookBroadcaster] broadcast error: #{e.message}")
  end
end
