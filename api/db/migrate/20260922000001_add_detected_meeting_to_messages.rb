# A meeting OpenAI read out of an inbound body with no ICS attached
# (docs/Meeting-Invites.md "Detected meetings"): {title, start, end, location},
# floating wall-clock times. Served as a PUBLISH `invite` so every client offers
# "Add to calendar".
class AddDetectedMeetingToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :detected_meeting, :jsonb, if_not_exists: true
  end
end
