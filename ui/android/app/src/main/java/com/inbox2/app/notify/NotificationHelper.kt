package com.inbox2.app.notify

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.os.Build
import androidx.core.app.NotificationCompat
import com.inbox2.app.MainActivity
import com.inbox2.app.R
import com.inbox2.app.cloud.CloudSession
import com.inbox2.app.cloud.ImageProxy
import com.inbox2.app.cloud.PrivacyStore
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.model.AccountKey
import com.inbox2.app.model.ConversationAction
import com.inbox2.app.model.InboxFilter
import com.inbox2.app.model.MailAddress
import com.inbox2.app.model.MailFolder
import com.inbox2.app.model.RelativeTime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Local notifications for new mail (iOS NotificationManager). The engine's `new-message`
 * event is fed here (server-free, like iOS) and raised as a notification; an MX
 * `new_message` push (data-only, FcmService) lands on the same path. No APNs/Rails
 * rendering: while running, the in-process engine syncs + scans rules and fires directly;
 * when backgrounded, the WorkManager periodic sync wakes the engine and the post-sync rule
 * scan re-emits `new-message`.
 *
 * Every banner carries Mark as read / Archive / Trash (NotificationActions) — inline on
 * the card, which is the one place Android beats the iOS long-press menu. The ongoing
 * "newest unread" card ([refreshOngoing]) is the Android counterpart of the iOS Mail Live
 * Activity: one silent, non-dismissable notification with the newest unread thread, the
 * same three buttons and a "+N" line, advancing after each action and leaving when
 * nothing is unread. Android 16+ promotes it to a Live Update (status-bar chip).
 */
object NotificationHelper {
    const val CHANNEL_ID = "inbox2_mail"
    /** The ongoing newest-unread card: own channel so it can be silent + low. */
    const val LIVE_CHANNEL_ID = "inbox2_mail_live"
    const val LIVE_NOTIFICATION_ID = 9_002
    private var idCounter = 1000

    /** A favicon from these says "Google", not who wrote to you (web lib/otp.js FREEMAIL). */
    private val FREEMAIL = setOf("gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "yahoo.com", "icloud.com", "me.com")

    /** Intent extra carrying the tapped notification's conversation key. */
    const val EXTRA_CONVERSATION_KEY = "conversation_key"

    // Notification preferences (iOS NotificationManager.newMailKey / soundKey). Same key
    // strings as iOS; both default on. Read on every post, toggled from Settings › Preferences.
    private const val PREFS = "inbox2_notify"
    const val KEY_NEW_MAIL = "inbox2_notify_new_mail"
    const val KEY_SOUND = "inbox2_notify_sound"
    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    fun newMailEnabled(context: Context) = prefs(context).getBoolean(KEY_NEW_MAIL, true)
    fun soundEnabled(context: Context) = prefs(context).getBoolean(KEY_SOUND, true)
    fun setNewMailEnabled(context: Context, on: Boolean) = prefs(context).edit().putBoolean(KEY_NEW_MAIL, on).apply()
    fun setSoundEnabled(context: Context, on: Boolean) = prefs(context).edit().putBoolean(KEY_SOUND, on).apply()

    /**
     * Conversation key of a tapped notification (set by MainActivity from the intent,
     * consumed by RootTabs which opens the thread). A flow — not a direct call — so a
     * cold-launch tap survives until the composition exists.
     */
    val tappedConversation = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)

    /** Calendar event key of a tapped meeting alarm (MeetingAlarms) — held the same way,
     *  RootTabs opens the Calendar tab on that event's detail (iOS pendingEventKey). */
    val tappedEvent = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)

    /** The UI's mx session while the activity is up (MainActivity sets it). Lets a
     *  notification action and the ongoing card use the signed-in session (mirror +
     *  list refresh) instead of a bare API call. iOS: PushRegistrar.cloud. */
    @Volatile var liveCloud: CloudSession? = null

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = context.getSystemService(NotificationManager::class.java)
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "New mail", NotificationManager.IMPORTANCE_DEFAULT)
                        .apply { description = "New conversations in your inbox" }
                )
            }
            if (mgr.getNotificationChannel(LIVE_CHANNEL_ID) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(LIVE_CHANNEL_ID, "Newest unread", NotificationManager.IMPORTANCE_LOW)
                        .apply { description = "A pinned card with your newest unread message" }
                )
            }
        }
    }

    /** Tap → open the thread in the app. requestCode = the notification id: a shared
     *  requestCode + FLAG_UPDATE_CURRENT would rewrite every pending tap to the newest. */
    private fun openIntent(context: Context, key: String?, requestCode: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            key?.let { putExtra(EXTRA_CONVERSATION_KEY, it) }
        }
        return PendingIntent.getActivity(
            context, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun NotificationCompat.Builder.mailActions(
        context: Context, key: String, accountKey: String?, orgId: String?, fromLive: Boolean,
    ): NotificationCompat.Builder {
        NotificationActions.buttons.forEach { (action, title) ->
            addAction(0, title, NotificationActions.pendingIntent(context, action.verb, key, accountKey, orgId, fromLive))
        }
        return this
    }

    /** Raise a notification from a `new-message` event payload (best-effort parse).
     *  Engine payloads carry `key` + `accountKey`; an MX push carries `organization_id`
     *  (FcmService maps its title/body onto `from_address`/`subject`). */
    fun postNewMessage(context: Context, payloadJson: String) {
        if (!newMailEnabled(context)) return   // "New mail" toggle off (iOS newMailEnabled guard)
        ensureChannel(context)
        val o = runCatching { JSONObject(payloadJson) }.getOrNull()
        val from = o?.optString("from_address")?.ifEmpty { null }
        val subject = o?.optString("subject")?.ifEmpty { null } ?: "New message"
        val snippet = o?.optString("snippet").orEmpty()
        val title = from?.let { MailAddress.parse(it).name } ?: "inbox2"
        val accountKey = o?.optString("accountKey")?.ifEmpty { null }
        val orgId = o?.optString("organization_id")?.ifEmpty { null }

        val key = o?.optString("key")?.ifEmpty { null }
        val otp = o?.optJSONObject("otp")
        val otpCode = otp?.optString("code")?.ifEmpty { null }
        val otpLink = otp?.optString("link")?.ifEmpty { null }
        // Tag every notification with its conversation key so removeDelivered()
        // can cancel it later. Stable id per conversation; keyless mail falls back
        // to the counter.
        val id = key?.hashCode() ?: idCounter++

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher_monochrome)
            .setContentTitle(title)
            .setContentText(subject)
            .setAutoCancel(true)
            .setSilent(!soundEnabled(context))   // "Sound" toggle off → post silently (iOS soundEnabled)
            .setContentIntent(openIntent(context, key, id))
        if (snippet.isNotEmpty()) builder.setStyle(NotificationCompat.BigTextStyle().bigText("$subject\n$snippet"))
        // Sign-in mail (core otp.rs / Rails `otp_*` push keys): the code or link leads, and
        // the first button uses it. Archive/Trash are the ordinary mail buttons.
        val otpHost = otp?.optString("host")?.ifEmpty { null }
        // An MX push names the sender's domain in `from_host` (its title is a display name, no address).
        val senderHost = o?.optString("from_host")?.ifEmpty { null }
            ?: from?.let { MailAddress.parse(it).email.substringAfter('@', "") }?.ifEmpty { null }
        // Large icon, as on the desktop card: the sender's face (Meta DMs), else the sign-in
        // link's host, else the sender's domain — never a freemail one (it names the provider).
        val iconUrl = o?.optString("from_avatar")?.ifEmpty { null }
            ?: (otpHost ?: senderHost?.takeUnless { it.lowercase() in FREEMAIL })?.let { "https://$it/favicon.ico" }
        if (otpCode != null || otpLink != null) {
            builder.setContentTitle(if (otpCode != null) "Code $otpCode" else "Sign-in link · ${otpHost ?: "open"}")
                .setContentText("$title · $subject")
                .setStyle(null)
        }
        if (key != null) {
            if (otpCode != null || otpLink != null) {
                builder.addAction(0, if (otpCode != null) "Copy & delete" else "Open & delete",
                    if (otpCode != null) NotificationActions.pendingIntent(context, ConversationAction.Trash.verb, key, accountKey, orgId, fromLive = false, copyCode = otpCode)
                    else OtpLinkActivity.pendingIntent(context, otpLink!!, key, accountKey, orgId))
                listOf(ConversationAction.Archive to "Archive", ConversationAction.Trash to "Delete").forEach { (action, label) ->
                    builder.addAction(0, label, NotificationActions.pendingIntent(context, action.verb, key, accountKey, orgId, fromLive = false))
                }
            } else {
                builder.mailActions(context, key, accountKey, orgId, fromLive = false)
            }
        }

        runCatching {
            androidx.core.app.NotificationManagerCompat.from(context).notify(key, id, builder.build())
        }
        // Sender icon: posted without it first, re-posted with it once the Rails proxy
        // returns it (never fetched from the site itself — privacy rule). A failure, an .ico
        // BitmapFactory can't decode, or no inbox2 sign-in leaves the card as it is.
        if (iconUrl != null) CoroutineScope(Dispatchers.IO).launch {
            // Socket timeouts, not withTimeout: a coroutine timeout can't cut a blocking read.
            val bytes = ImageProxy.fetch(iconUrl, PrivacyStore(context).bearer(), timeoutMs = 1_500)
                ?.second ?: return@launch
            val icon = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return@launch
            // The banner may have been acted on meanwhile — don't resurrect it.
            if (key != null && key !in deliveredConversationKeys(context)) return@launch
            runCatching {
                // onlyAlertOnce on the re-post only: the icon update must not ring twice.
                androidx.core.app.NotificationManagerCompat.from(context)
                    .notify(key, id, builder.setLargeIcon(icon).setOnlyAlertOnce(true).build())
            }
        }
        // The pinned card shows the newest unread — advance it to this one.
        EngineModel.peek()?.let { engine ->
            CoroutineScope(Dispatchers.IO).launch { refreshOngoing(context, engine, liveCloud) }
        }
    }

    /**
     * Bring the ongoing card in line with the inbox (iOS MailActivityManager.refresh):
     * newest unread across channels (SQLite) and MX (current org, when signed in) → post
     * or update; nothing unread → cancel. `excluding` drops the thread a button just acted
     * on, so the card moves on before the action lands. Off the main thread (SQLite + API).
     */
    suspend fun refreshOngoing(context: Context, engine: EngineModel, cloud: CloudSession?, excluding: String? = null) {
        if (!newMailEnabled(context)) { cancelOngoing(context); return }
        val (newest, unread) = withContext(Dispatchers.IO) {
            val local = engine.store.conversations(null, MailFolder.INBOX, InboxFilter.UNREAD, "")
                .filter { it.id != excluding }
            val mx = runCatching {
                val org = cloud?.takeIf { it.isSignedIn }?.activeOrg?.value ?: return@runCatching emptyList()
                cloud.conversations(org, MailFolder.INBOX, "", view = "Unread").filter { it.id != excluding }
            }.getOrDefault(emptyList())
            val newest = (local.take(1) + mx.take(1)).maxByOrNull { RelativeTime.parse(it.updatedAt)?.time ?: 0L }
            newest to (engine.store.unreadCount(null) + mx.size)
        }
        if (newest == null) { cancelOngoing(context); return }
        ensureChannel(context)
        val from = MailAddress.parse(newest.fromAddress)
        val isDomain = AccountKey.isDomain(newest.accountKey)
        val others = (unread - 1).coerceAtLeast(0)
        val builder = NotificationCompat.Builder(context, LIVE_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher_monochrome)
            .setContentTitle(from.name.ifEmpty { from.email })
            .setContentText(newest.subject.ifEmpty { "(No subject)" })
            .setStyle(NotificationCompat.BigTextStyle().bigText(
                listOf(newest.subject.ifEmpty { "(No subject)" }, newest.snippet).filter { it.isNotEmpty() }.joinToString("\n")))
            .setSubText(if (others > 0) "+$others more unread" else null)
            // Launchers that show a number read it off the notification (iOS AppBadge).
            .setNumber(unread.coerceAtLeast(1))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_EMAIL)
            .setContentIntent(openIntent(context, newest.id, LIVE_NOTIFICATION_ID))
            .mailActions(
                context, newest.id,
                accountKey = if (isDomain) null else newest.accountKey,
                orgId = if (isDomain) newest.accountKey else null,
                fromLive = true,
            )
        // Android 16 Live Updates: the lock-screen / status-bar chip. No-op below 16.
        builder.setRequestPromotedOngoing(true)
        runCatching { androidx.core.app.NotificationManagerCompat.from(context).notify(LIVE_NOTIFICATION_ID, builder.build()) }
    }

    fun cancelOngoing(context: Context) {
        runCatching { androidx.core.app.NotificationManagerCompat.from(context).cancel(LIVE_NOTIFICATION_ID) }
    }

    /** Conversation keys with a notification currently in the tray (their tags).
     *  Input to channel reconciliation; excludes untagged entries (the ongoing card,
     *  the transient "Syncing" foreground notification). */
    fun deliveredConversationKeys(context: Context): List<String> = runCatching {
        val mgr = context.getSystemService(NotificationManager::class.java)
        mgr.activeNotifications.mapNotNull { it.tag }.distinct()
    }.getOrDefault(emptyList())

    /** Clear any tray notification(s) for these conversations — drives both a
     *  Rails `remove_notification` push (MX mail dealt with elsewhere) and the
     *  post-sync reconciliation for local channels. Cancels by the exact (tag,
     *  id) on screen so it works regardless of who posted it. */
    fun removeDelivered(context: Context, conversationKeys: Collection<String>) {
        val wanted = conversationKeys.toSet()
        if (wanted.isEmpty()) return
        runCatching {
            val mgr = context.getSystemService(NotificationManager::class.java)
            mgr.activeNotifications
                .filter { it.tag != null && it.tag in wanted }
                .forEach { mgr.cancel(it.tag, it.id) }
        }
    }
}
