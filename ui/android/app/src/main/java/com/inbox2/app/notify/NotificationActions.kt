package com.inbox2.app.notify

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.inbox2.app.SecureStore
import com.inbox2.app.cloud.CloudClient
import com.inbox2.app.cloud.CloudSession
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.model.ConversationAction
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * Notification-button actions (iOS NotificationManager.PendingAction + drainPendingActions).
 * Every new-mail notification — and the ongoing "newest unread" card — carries
 * Mark as read / Archive / Trash. They run WITHOUT opening the app: the receiver persists
 * the action and drops the banner, an expedited worker applies it through the same
 * routers the UI uses (engine `perform` for channels, cloud bulk for MX), and the queue
 * is drained again at launch so an action taken while the engine was down is never lost.
 */
object NotificationActions {
    private const val TAG = "com.inbox2.notify"
    private const val PREFS = "inbox2_notify"   // the NotificationHelper toggles' file
    private const val KEY_QUEUE = "inbox2_pending_notification_actions"   // same key as iOS
    const val ACTION = "com.inbox2.app.NOTIFICATION_ACTION"
    const val EXTRA_VERB = "verb"
    const val EXTRA_CONVERSATION_KEY = "conversation_key"
    const val EXTRA_ACCOUNT_KEY = "account_key"
    const val EXTRA_ORG_ID = "org_id"
    /** The button lived on the ongoing card: drop the card at once, the drain re-posts it. */
    const val EXTRA_FROM_LIVE = "from_live"
    /** Sign-in card "Copy & delete": the code to put on the clipboard before trashing. */
    const val EXTRA_COPY_CODE = "copy_code"

    /** Button order mirrors iOS (Trash last, destructive). */
    val buttons: List<Pair<ConversationAction, String>> = listOf(
        ConversationAction.MarkRead to "Mark as read",
        ConversationAction.Archive to "Archive",
        ConversationAction.Trash to "Trash",
    )

    data class Pending(val verb: String, val conversationKey: String, val accountKey: String?, val orgId: String?)

    fun pendingIntent(
        context: Context, verb: String, conversationKey: String, accountKey: String?, orgId: String?, fromLive: Boolean,
        copyCode: String? = null,
    ): PendingIntent {
        val intent = Intent(context, NotificationActionReceiver::class.java).apply {
            action = ACTION
            putExtra(EXTRA_VERB, verb)
            putExtra(EXTRA_CONVERSATION_KEY, conversationKey)
            accountKey?.let { putExtra(EXTRA_ACCOUNT_KEY, it) }
            orgId?.let { putExtra(EXTRA_ORG_ID, it) }
            putExtra(EXTRA_FROM_LIVE, fromLive)
            copyCode?.let { putExtra(EXTRA_COPY_CODE, it) }
        }
        // One requestCode per (thread, verb, surface): a shared code + UPDATE_CURRENT would
        // rewrite every button to the newest notification's extras.
        return PendingIntent.getBroadcast(
            context, "$conversationKey|$verb|$fromLive|${copyCode != null}".hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** Queue [verb] on a thread, drop its banner, and kick the worker — the receiver's
     *  work, shared with [OtpLinkActivity] (which can't route through a broadcast). */
    fun submit(context: Context, a: Pending, fromLive: Boolean) {
        enqueue(context, a)
        // The thread's banner goes first — not on the post-sync reconcile (iOS perform()).
        NotificationHelper.removeDelivered(context, listOf(a.conversationKey))
        if (fromLive) NotificationHelper.cancelOngoing(context)
        NotificationActionWorker.enqueue(context)
    }

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Synchronized
    fun enqueue(context: Context, a: Pending) = save(context, load(context) + a)

    /** Drop one applied action from the live queue (a tap during the drain has appended
     *  since the drain's snapshot was taken). */
    @Synchronized
    private fun remove(context: Context, a: Pending) = save(context, load(context) - a)

    @Synchronized
    private fun load(context: Context): List<Pending> = runCatching {
        val arr = JSONArray(prefs(context).getString(KEY_QUEUE, null) ?: return emptyList())
        (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            Pending(o.getString("verb"), o.getString("conversationKey"),
                o.optString("accountKey").ifEmpty { null }, o.optString("orgId").ifEmpty { null })
        }
    }.getOrDefault(emptyList())

    @Synchronized
    private fun save(context: Context, queue: List<Pending>) {
        val arr = JSONArray()
        queue.forEach { a ->
            arr.put(JSONObject().put("verb", a.verb).put("conversationKey", a.conversationKey)
                .put("accountKey", a.accountKey ?: "").put("orgId", a.orgId ?: ""))
        }
        prefs(context).edit().putString(KEY_QUEUE, if (queue.isEmpty()) null else arr.toString()).apply()
    }

    /** Apply every queued action; drop each on success, keep it for the next drain on
     *  failure. Boots the engine if needed (the worker path). */
    suspend fun drain(context: Context) {
        val queue = load(context)
        if (queue.isEmpty()) return
        val engine = EngineModel.get(context.applicationContext)
        for (a in queue) {
            val ok = runCatching {
                when {
                    a.orgId != null -> { performCloud(context, a); true }
                    a.accountKey != null -> engine.perform(a.accountKey, listOf(a.conversationKey), a.verb)
                    else -> true   // nothing to route it to; drop rather than retry forever
                }
            }.onFailure { Log.w(TAG, "notification action ${a.verb} failed: ${it.message}") }.getOrDefault(false)
            Log.i(TAG, "notification action ${a.verb} on ${a.conversationKey}: ${if (ok) "ok" else "failed"}")
            if (ok) remove(context, a)   // failures stay queued for the next drain
        }
        NotificationHelper.refreshOngoing(context, engine, NotificationHelper.liveCloud)
    }

    private suspend fun performCloud(context: Context, a: Pending) {
        val orgId = a.orgId ?: return
        val live = NotificationHelper.liveCloud
        if (live != null && live.isSignedIn) { live.perform(orgId, listOf(a.conversationKey), a.verb); return }
        // No UI session — the process was woken just for the button. One direct API call
        // with the stored bearer. ponytail: bypasses the MX mirror (it catches up on its
        // next pull); go through a restored CloudSession if that ever matters.
        val token = withContext(Dispatchers.IO) { SecureStore.get(context, SecureStore.MX_TOKEN) }
            ?: error("not signed in to inbox2 mx")
        CloudClient().apply { setToken(token) }.bulk(orgId, listOf(a.conversationKey), CloudSession.bulkAction(a.verb))
    }
}

/** The tray button. Persist + clear the banner here (cheap, main thread), apply in the worker. */
class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != NotificationActions.ACTION) return
        val verb = intent.getStringExtra(NotificationActions.EXTRA_VERB) ?: return
        val key = intent.getStringExtra(NotificationActions.EXTRA_CONVERSATION_KEY) ?: return
        // Sign-in card "Copy & delete": clipboard first (background writes are allowed;
        // only reads are restricted), then the trash below like any other button.
        intent.getStringExtra(NotificationActions.EXTRA_COPY_CODE)?.let { copyCode(context, it) }
        NotificationActions.submit(context, NotificationActions.Pending(
            verb, key,
            intent.getStringExtra(NotificationActions.EXTRA_ACCOUNT_KEY),
            intent.getStringExtra(NotificationActions.EXTRA_ORG_ID),
        ), intent.getBooleanExtra(NotificationActions.EXTRA_FROM_LIVE, false))
    }

    private fun copyCode(context: Context, raw: String) {
        val code = raw.filterNot { it == ' ' || it == '-' }   // "123-456" → "123456"
        val clip = android.content.ClipData.newPlainText("Sign-in code", code)
        // Keep the code out of the clipboard preview overlay (API 33+ reads the flag).
        clip.description.extras = android.os.PersistableBundle().apply {
            putBoolean("android.content.extra.IS_SENSITIVE", true)
        }
        runCatching {
            context.getSystemService(android.content.ClipboardManager::class.java).setPrimaryClip(clip)
            android.widget.Toast.makeText(context.applicationContext, "Code copied", android.widget.Toast.LENGTH_SHORT).show()
        }
    }
}

/** Expedited drain — a full engine boot doesn't fit a receiver's window. */
class NotificationActionWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        NotificationActions.drain(applicationContext)
        return Result.success()
    }

    // Expedited work runs as a foreground service before API 31 (see SyncWorker).
    override suspend fun getForegroundInfo(): androidx.work.ForegroundInfo {
        NotificationHelper.ensureChannel(applicationContext)
        val notification = androidx.core.app.NotificationCompat
            .Builder(applicationContext, NotificationHelper.LIVE_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("Applying…")
            .setOngoing(true)
            .setSilent(true)
            .build()
        return androidx.work.ForegroundInfo(FOREGROUND_ID, notification)
    }

    companion object {
        private const val NAME = "inbox2-notification-actions"
        private const val FOREGROUND_ID = 9_003

        fun enqueue(context: Context) {
            val req = OneTimeWorkRequestBuilder<NotificationActionWorker>()
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .build()
            // APPEND_OR_REPLACE: a second button while the first drain runs queues another
            // pass, which picks up everything still pending.
            WorkManager.getInstance(context).enqueueUniqueWork(NAME, ExistingWorkPolicy.APPEND_OR_REPLACE, req)
        }
    }
}

/**
 * Sign-in card "Open & delete". A receiver may not start an activity from a notification
 * (Android 12+ trampoline ban), so the button is a PendingIntent.getActivity to this
 * no-UI activity: open the link, and only once that worked trash the thread.
 */
class OtpLinkActivity : android.app.Activity() {
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        val link = intent.getStringExtra(EXTRA_LINK)
        val key = intent.getStringExtra(NotificationActions.EXTRA_CONVERSATION_KEY)
        // Only web links — the URL comes out of an email.
        val uri = link?.let(android.net.Uri::parse)?.takeIf { it.scheme == "https" || it.scheme == "http" }
        val opened = uri != null && runCatching {
            startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.isSuccess
        if (opened && key != null) {
            NotificationActions.submit(this, NotificationActions.Pending(
                ConversationAction.Trash.verb, key,
                intent.getStringExtra(NotificationActions.EXTRA_ACCOUNT_KEY),
                intent.getStringExtra(NotificationActions.EXTRA_ORG_ID),
            ), fromLive = false)
        }
        finish()
    }

    companion object {
        const val EXTRA_LINK = "link"

        fun pendingIntent(context: Context, link: String, conversationKey: String, accountKey: String?, orgId: String?): PendingIntent {
            val intent = Intent(context, OtpLinkActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_HISTORY)
                putExtra(EXTRA_LINK, link)
                putExtra(NotificationActions.EXTRA_CONVERSATION_KEY, conversationKey)
                accountKey?.let { putExtra(NotificationActions.EXTRA_ACCOUNT_KEY, it) }
                orgId?.let { putExtra(NotificationActions.EXTRA_ORG_ID, it) }
            }
            return PendingIntent.getActivity(
                context, "$conversationKey|open-link".hashCode(), intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
    }
}
