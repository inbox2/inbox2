# Per-user stream for cloud-push "go sync" signals on local channels (Gmail/Office365).
# Auth is handled by ApplicationCable::Connection (token query param). See docs/Cloud-Push.md.
class PushSyncChannel < ApplicationCable::Channel
  def subscribed
    stream_from "push_sync_#{current_user.key}"
  end
end
