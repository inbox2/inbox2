# Per-user "your zones changed" signal (docs/Calendar.md "Zones"): a zone,
# category or card dismissal was written on another device. Content-free — the
# client refetches. Auth is ApplicationCable::Connection's.
class ZoneChannel < ApplicationCable::Channel
  def subscribed
    stream_from ZoneSync.stream(current_user)
  end
end
