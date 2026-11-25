package com.inbox2.app.fcm

import android.util.Log
import com.inbox2.app.data.InboxStore
import com.inbox2.app.engine.EngineModel
import java.io.File
import com.inbox2.app.notify.NotificationHelper
import com.inbox2.app.notify.SyncWorker
import com.inbox2.app.notify.ZoneAlerts
import com.inbox2.app.notify.ZoneSyncWorker
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONObject

/**
 * FCM receiver (docs/Cloud-Push.md "Mobile push"). Two message kinds from the API:
 *
 * - `channel_sync` — data-only silent nudge: a Gmail/Microsoft mailbox changed. The
 *   payload is content-free by design; we enqueue an expedited sync and the engine's
 *   `new-message` events post the real (local) notifications. Work runs through
 *   WorkManager because onMessageReceived's execution budget (~10s) is shorter than
 *   a full sync.
 * - `new_message` — MX-pool alert. Data-only on purpose (a `notification` message
 *   would be rendered by the system while backgrounded: no action buttons, no ongoing
 *   card), so it reaches here in every app state and is posted through the same
 *   NotificationHelper as engine mail — identical tap routing + the three buttons.
 * - `zones_changed` — silent: a zone, category or dismissal changed on the account.
 *   A `dismissed` occurrence id is applied at once; then the live UI refetches, or
 *   (no UI collecting) [com.inbox2.app.notify.ZoneSyncWorker] does.
 * - `meta_event` — silent Meta (Instagram/Messenger/WhatsApp) relay nudge carrying a
 *   buffer key; we fetch + verify + apply that one event (WhatsApp has no pull API).
 */
class FcmService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        FcmTokenManager.register(applicationContext, token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        when (message.data["type"]) {
            "channel_sync" -> {
                Log.i(TAG, "channel_sync push for ${message.data["email"] ?: "?"} — enqueuing sync")
                SyncWorker.syncNow(applicationContext)
            }
            "meta_event" -> {
                // Meta webhook relay: fetch + verify + apply the buffered event by key.
                val key = message.data["event_key"]
                if (key.isNullOrEmpty()) {
                    Log.w(TAG, "meta_event push missing event_key")
                } else {
                    Log.i(TAG, "meta_event push — enqueuing ingest $key")
                    SyncWorker.ingestMetaEvent(applicationContext, key)
                }
            }
            "zones_changed" -> {
                message.data["dismissed"]?.takeIf { it.isNotEmpty() }?.let {
                    ZoneAlerts.applyRemoteDismissal(applicationContext, it)
                }
                ZoneAlerts.remoteChanged.value += 1
                if (ZoneAlerts.remoteChanged.subscriptionCount.value == 0) ZoneSyncWorker.enqueue(applicationContext)
            }
            "remove_notification" -> {
                // An MX conversation left the inbox on another device — clear its
                // stale tray/lockscreen banner here (Path A). A `tags` list instead
                // means local-channel mail dealt with elsewhere (Path C).
                val key = message.data["conversation_id"]
                val tags = message.data["tags"]?.split(",")?.filter { it.isNotEmpty() }?.toSet()
                if (!tags.isNullOrEmpty()) {
                    Log.i(TAG, "remove_notification push — ${tags.size} channel tag(s)")
                    val store = EngineModel.peek()?.store
                        ?: InboxStore(File(File(applicationContext.filesDir, "inbox2"), "inbox2.db").path)
                    NotificationHelper.removeTagged(applicationContext, store, tags)
                } else if (key.isNullOrEmpty()) {
                    Log.w(TAG, "remove_notification push missing conversation_id")
                } else {
                    Log.i(TAG, "remove_notification push — clearing $key")
                    NotificationHelper.removeDelivered(applicationContext, listOf(key))
                }
            }
            "new_message" -> {
                // Title/body ride the data map; `message.notification` is the pre-data-only
                // server shape, kept as a fallback.
                val payload = JSONObject()
                    .put("from_address", message.data["title"] ?: message.notification?.title ?: "inbox2")
                    .put("subject", message.data["body"] ?: message.notification?.body ?: "")
                    .put("key", message.data["conversation_id"] ?: JSONObject.NULL)
                    .put("organization_id", message.data["organization_id"] ?: JSONObject.NULL)
                    .put("from_host", message.data["from_host"] ?: "")
                // Sign-in mail: Rails' flat `otp_*` keys → the engine payload's `otp` object.
                message.data["otp_code"]?.takeIf { it.isNotEmpty() }?.let {
                    payload.put("otp", JSONObject().put("code", it).put("host", message.data["otp_host"] ?: ""))
                } ?: message.data["otp_link"]?.takeIf { it.isNotEmpty() }?.let {
                    payload.put("otp", JSONObject().put("link", it).put("host", message.data["otp_host"] ?: ""))
                }
                NotificationHelper.postNewMessage(applicationContext, payload.toString())
            }
            else -> Log.i(TAG, "unknown push type: ${message.data["type"]}")
        }
    }

    private companion object {
        const val TAG = "FcmService"
    }
}
