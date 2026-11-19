# Hard-revokes a user's access everywhere, in real time.
#
# Two layers:
#   1. Guaranteed — delete the DB sessions. Every authenticated request
#      re-resolves the bearer token against the sessions table, so the very
#      next HTTP call 401s. This always happens.
#   2. Best-effort live kick — tell any open clients to log out *now* (an idle
#      tab/desktop window won't otherwise notice until its next request). We
#      reuse the per-user PushSyncChannel stream the web/desktop client already
#      holds open, and also force-disconnect the cable connection itself
#      (ActionCable only authenticates at connect, so a deleted session does not
#      drop a live socket on its own).
class SessionRevoker
  FORCE_LOGOUT = "force_logout".freeze

  def self.revoke_user!(user, reason: "access_revoked")
    user.sessions.delete_all

    ActionCable.server.broadcast(
      "push_sync_#{user.key}",
      { type: FORCE_LOGOUT, reason: reason }
    )
    ActionCable.server.remote_connections.where(current_user: user).disconnect
  rescue => e
    # The DB revoke above is the real guarantee; never let a cable hiccup block it.
    Rails.logger.warn("[SessionRevoker] live kick failed for #{user.key}: #{e.class}: #{e.message}")
  end
end
