# ActivityKit push tokens for the iOS "Mail" Live Activity (docs/Cloud-Push.md
# "Live Activity"). `live_activity_start_token` lets Rails START the activity
# while the app is not running (push-to-start, iOS 17.2+); `live_activity_token`
# is the running activity's own token for UPDATE pushes, cleared when it ends.
# Own file so production actually migrates; also in the initial schema, hence
# `if_not_exists`.
class AddLiveActivityTokensToPushDevices < ActiveRecord::Migration[8.1]
  def change
    add_column :push_devices, :live_activity_start_token, :string, if_not_exists: true
    add_column :push_devices, :live_activity_token, :string, if_not_exists: true
  end
end
