# Tells a user's other devices their zones changed (docs/Calendar.md "Zones"):
# an ActionCable hint for open web/desktop windows plus a silent mobile push,
# so a card dismissed on one device leaves the others and new or moved zones
# show without waiting for the next poll. Content-free: clients refetch.
class ZoneSync
  def self.stream(user)
    "zones_#{user.key}"
  end

  def self.notify(user, dismissed: nil)
    payload = { type: "zones_changed", dismissed: dismissed }.compact
    ActionCable.server.broadcast(stream(user), payload)
    MobilePushSender.zones_changed(user, dismissed: dismissed)
  rescue => e
    Rails.logger.warn("[ZoneSync] notify failed: #{e.message}")
  end
end
