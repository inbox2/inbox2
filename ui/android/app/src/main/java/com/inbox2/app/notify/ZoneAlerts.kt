package com.inbox2.app.notify

import com.inbox2.app.model.DateFmt
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.inbox2.app.MainActivity
import com.inbox2.app.R
import com.inbox2.app.cloud.CloudZone
import com.inbox2.app.cloud.CloudZoneCategory
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * "You're in the zone" alerts. A zone with `notify` gets two AlarmManager alarms: at its
 * start [ZoneAlarmReceiver] posts an ongoing notification (own "Zones" channel) with a
 * count-down chronometer to the zone's end; at its end it re-posts the same notification
 * (same id) as "Zone ended". It never times out — it stays until "Done", by product
 * decision. Done records the zone id as dismissed; the in-app card reads the same set,
 * plus the [shown] set so it too keeps an ended zone up until Done. Alarms are exact
 * when the user allows it (`SCHEDULE_EXACT_ALARM`), else `setAndAllowWhileIdle`, which
 * the system may deliver minutes late; a late alarm still posts, in whatever state the
 * zone is in by then. They're re-armed by [reconcile] after every zone fetch (sign-in,
 * app start, each edit).
 * Alarms die with a reboot, so [reconcile] also caches what it armed; the receiver
 * re-arms from that cache on BOOT_COMPLETED / MY_PACKAGE_REPLACED ([rearmFromCache]).
 * A repeating zone arrives as one row per occurrence (id `zon_x@…`), so every id-derived
 * key here (alarm data URI, notification id, dismissed set) is per occurrence.
 * Dismissals sync across devices: Done queues the occurrence in a pending set that
 * [ZoneSyncWorker] (and every [com.inbox2.app.cloud.CloudSession.refreshZones]) POSTs
 * until it lands; a zone fetched with `dismissed: true`, or an FCM `zones_changed`
 * carrying `dismissed`, is applied here via [applyRemoteDismissal] / [reconcile].
 */
object ZoneAlerts {
    const val CHANNEL_ID = "inbox2_zones"
    private const val PREFS = "inbox2_zones"
    private const val KEY_DISMISSED = "dismissed"
    private const val KEY_ARMED = "armed"
    private const val KEY_CACHE = "armed_zones"
    private const val KEY_SHOWN = "shown"
    private const val KEY_PENDING = "pending_dismissals"
    internal const val ACTION_START = "com.inbox2.app.ZONE_START"
    internal const val ACTION_END = "com.inbox2.app.ZONE_END"
    internal const val ACTION_DONE = "com.inbox2.app.ZONE_DONE"
    internal const val EXTRA_ID = "zone_id"
    private const val EXTRA_NAME = "zone_name"
    private const val EXTRA_NOTE = "zone_note"
    private const val EXTRA_CATEGORY = "zone_category"
    internal const val EXTRA_END = "zone_end"

    private fun prefs(c: Context) = c.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private val _dismissed = MutableStateFlow<Set<String>?>(null)
    /** Zone ids the user marked Done — shared by the notification and the in-app card. */
    fun dismissed(c: Context): StateFlow<Set<String>?> {
        if (_dismissed.value == null) _dismissed.value = prefs(c).getStringSet(KEY_DISMISSED, emptySet())!!.toSet()
        return _dismissed
    }

    private val _shown = MutableStateFlow<Set<String>?>(null)
    /** Zone ids whose alert was posted — the card keeps these up after the zone ends. */
    fun shown(c: Context): StateFlow<Set<String>?> {
        if (_shown.value == null) _shown.value = prefs(c).getStringSet(KEY_SHOWN, emptySet())!!.toSet()
        return _shown
    }

    private fun markShown(c: Context, zoneId: String) {
        val cur = shown(c).value.orEmpty()
        if (zoneId in cur) return
        _shown.value = cur + zoneId
        prefs(c).edit().putStringSet(KEY_SHOWN, cur + zoneId).apply()
    }

    /** Done here: dismiss locally, then queue the dismissal for the server so every
     *  other device drops the card too. [endMs] is the occurrence's end (the server
     *  keeps the dismissal until then). */
    fun dismiss(c: Context, zoneId: String, endMs: Long) {
        applyRemoteDismissal(c, zoneId)
        synchronized(this) {
            val p = prefs(c)
            p.edit().putStringSet(KEY_PENDING, p.getStringSet(KEY_PENDING, emptySet())!! + "$zoneId\n$endMs").apply()
        }
        ZoneSyncWorker.enqueue(c)
    }

    /** Dismissed on another device (or here): mark it, drop its notification and alarms. */
    fun applyRemoteDismissal(c: Context, zoneId: String) {
        val ctx = c.applicationContext
        val cur = dismissed(ctx).value.orEmpty()
        if (zoneId !in cur) {
            _dismissed.value = cur + zoneId
            prefs(ctx).edit().putStringSet(KEY_DISMISSED, cur + zoneId).apply()
        }
        cancelAlerts(ctx, zoneId)
    }

    /** POST every queued dismissal; each leaves the queue once the server has it. */
    suspend fun flushDismissals(c: Context, client: com.inbox2.app.cloud.CloudClient): Boolean {
        val p = prefs(c)
        var ok = true
        p.getStringSet(KEY_PENDING, emptySet())!!.toSet().forEach { entry ->
            val (id, end) = entry.split('\n', limit = 2)
            val sent = runCatching {
                client.dismissZone(id, java.time.Instant.ofEpochMilli(end.toLong()).toString())
            }.isSuccess
            if (sent) synchronized(this) { p.edit().putStringSet(KEY_PENDING, p.getStringSet(KEY_PENDING, emptySet())!! - entry).apply() }
            else ok = false
        }
        return ok
    }

    private fun pendingIds(c: Context) =
        prefs(c).getStringSet(KEY_PENDING, emptySet())!!.map { it.substringBefore('\n') }.toSet()

    /** A zone was edited here: the server dropped its dismissals so it alerts again —
     *  forget every occurrence of the series ([seriesKey] or `seriesKey@…`) locally too,
     *  queued POSTs included. */
    fun forgetSeries(c: Context, seriesKey: String) {
        val ctx = c.applicationContext
        val hit = { id: String -> id == seriesKey || id.startsWith("$seriesKey@") }
        val next = dismissed(ctx).value.orEmpty().filterNot(hit).toSet()
        _dismissed.value = next
        synchronized(this) {
            val p = prefs(ctx)
            p.edit().putStringSet(KEY_DISMISSED, next)
                .putStringSet(KEY_PENDING, p.getStringSet(KEY_PENDING, emptySet())!!.filterNot { hit(it.substringBefore('\n')) }.toSet())
                .apply()
        }
    }

    /** Bumped by an FCM `zones_changed`; a live UI refetches through its CloudSession. */
    val remoteChanged = MutableStateFlow(0)

    private fun cancelAlerts(ctx: Context, id: String) {
        val am = ctx.getSystemService(AlarmManager::class.java)
        am.cancel(alarmIntent(ctx, ACTION_START, id, null))
        am.cancel(alarmIntent(ctx, ACTION_END, id, null))
        NotificationManagerCompat.from(ctx).cancel(notificationId(id))
    }

    fun ensureChannel(c: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = c.getSystemService(NotificationManager::class.java)
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        mgr.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Zones", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "When a focus zone starts"
                setShowBadge(false) // the launcher badge is the unread count — keep it honest
            }
        )
    }

    /** What an alarm needs to post the notification — cached so a reboot can re-arm. */
    @Serializable
    private data class Armed(val id: String, val name: String, val category: String?, val note: String?, val start: Long, val end: Long)

    /** Arm start/end alarms per notify zone that hasn't ended (posting straight away for
     *  one already running), keep an ended-but-not-Done one's notification up, and cancel
     *  the alarms/notifications of zones that went away. */
    fun reconcile(c: Context, zones: List<CloudZone>, categories: List<CloudZoneCategory>) {
        val ctx = c.applicationContext
        val now = System.currentTimeMillis()
        // The server is the truth for dismissals it has: `dismissed: true` = clicked away on
        // some device; `false` for one we hold = un-dismissed by an edit elsewhere, unless our
        // own POST for it is still queued.
        val pending = pendingIds(ctx)
        val undone = zones.filter { !it.dismissed && it.id !in pending }.map { it.id }.toSet()
        val dismissed = dismissed(ctx).value.orEmpty() - undone + zones.filter { it.dismissed }.map { it.id }
        val shown = shown(ctx).value.orEmpty()
        val wanted = zones.filter { it.notify && it.id !in dismissed && (it.endMs > now || it.id in shown) }.map { z ->
            Armed(z.id, z.name, categories.firstOrNull { it.id == z.categoryId }?.name, z.note, z.startMs, z.endMs)
        }
        val gone = prefs(ctx).getStringSet(KEY_ARMED, emptySet())!! - wanted.map { it.id }.toSet()
        gone.forEach { cancelAlerts(ctx, it) }
        arm(ctx, wanted)
        // Keep the dismissed/shown sets to zones still in view, so they don't grow forever.
        val ids = zones.map { it.id }.toSet()
        val keptDismissed = dismissed.filter { it in ids }.toSet()
        val keptShown = shown(ctx).value.orEmpty().filter { it in ids }.toSet()
        prefs(ctx).edit().putStringSet(KEY_ARMED, wanted.map { it.id }.toSet())
            .putString(KEY_CACHE, Json.encodeToString(wanted))
            .putStringSet(KEY_DISMISSED, keptDismissed)
            .putStringSet(KEY_SHOWN, keptShown).apply()
        _dismissed.value = keptDismissed
        _shown.value = keptShown
    }

    /** After a reboot/app update: re-arm the cached zones (the alarms didn't survive). */
    fun rearmFromCache(c: Context) {
        val ctx = c.applicationContext
        val cached = prefs(ctx).getString(KEY_CACHE, null) ?: return
        val zones = runCatching { Json.decodeFromString<List<Armed>>(cached) }.getOrNull() ?: return
        val dismissed = dismissed(ctx).value.orEmpty()
        // The cache already holds only zones still running/upcoming or ended-but-not-Done;
        // notifications died with the reboot, so arm() re-posts the ones already started.
        arm(ctx, zones.filter { it.id !in dismissed })
    }

    private fun arm(ctx: Context, zones: List<Armed>) {
        val am = ctx.getSystemService(AlarmManager::class.java)
        val now = System.currentTimeMillis()
        zones.forEach { z ->
            val extras = Intent().apply {
                putExtra(EXTRA_NAME, z.name); putExtra(EXTRA_NOTE, z.note)
                putExtra(EXTRA_CATEGORY, z.category); putExtra(EXTRA_END, z.end)
            }
            if (z.start <= now) show(ctx, z.id, z.name, z.note, z.category, z.end)
            else setAlarm(am, z.start, alarmIntent(ctx, ACTION_START, z.id, extras))
            // Flips the notification to "Zone ended" (same id) instead of letting it vanish.
            if (z.end > now) setAlarm(am, z.end, alarmIntent(ctx, ACTION_END, z.id, extras))
        }
    }

    /** Exact when allowed. Without SCHEDULE_EXACT_ALARM (off by default on Android 14+)
     *  `setAndAllowWhileIdle` still fires in Doze, but it's inexact: the system may
     *  deliver it several minutes late (longer in deep Doze). A late alarm still posts. */
    private fun setAlarm(am: AlarmManager, at: Long, pi: PendingIntent) {
        val exact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || am.canScheduleExactAlarms()
        if (exact && runCatching { am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi) }.isSuccess) return
        am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
    }

    /** An alarm's PendingIntent. The zone id rides in the data URI and start/end differ by
     *  action, so each is distinct (filterEquals ignores extras); [extras] null = lookup only. */
    private fun alarmIntent(c: Context, action: String, id: String, extras: Intent?): PendingIntent {
        val i = Intent(c, ZoneAlarmReceiver::class.java).setAction(action)
            .setData(Uri.parse("inbox2-zone://$id")).putExtra(EXTRA_ID, id)
        extras?.extras?.let { i.putExtras(it) }
        return PendingIntent.getBroadcast(c, 0, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** Start or end alarm, on time or late: posts in whatever state the zone is in now. */
    internal fun showFromIntent(c: Context, i: Intent) {
        val id = i.getStringExtra(EXTRA_ID) ?: return
        if (id in dismissed(c).value.orEmpty()) return
        show(c, id, i.getStringExtra(EXTRA_NAME) ?: "Zone", i.getStringExtra(EXTRA_NOTE),
            i.getStringExtra(EXTRA_CATEGORY), i.getLongExtra(EXTRA_END, 0))
    }

    private fun show(c: Context, id: String, name: String, note: String?, category: String?, endMs: Long) {
        val ended = endMs <= System.currentTimeMillis()
        markShown(c, id)
        ensureChannel(c)
        val hhmm = DateFmt.hm(endMs)
        val until = "${category ?: "Zone"} ${if (ended) "ended at" else "until"} $hhmm"
        val body = listOfNotNull(until, note?.takeIf { it.isNotBlank() }).joinToString("\n")
        val open = PendingIntent.getActivity(c, notificationId(id),
            Intent(c, MainActivity::class.java).setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val done = PendingIntent.getBroadcast(c, notificationId(id),
            Intent(c, ZoneAlarmReceiver::class.java).setAction(ACTION_DONE)
                .setData(Uri.parse("inbox2-zone://$id")).putExtra(EXTRA_ID, id).putExtra(EXTRA_END, endMs),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(c, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher_monochrome)
            .setContentTitle(if (ended) "Zone ended: $name" else "You're in the zone: $name")
            .setContentText(until)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setOngoing(true).setAutoCancel(false).setOnlyAlertOnce(true)
            // Live count-down to the zone's end, drawn by the system; none once ended.
            .setUsesChronometer(!ended).setChronometerCountDown(!ended).setWhen(endMs).setShowWhen(!ended)
            // No setTimeoutAfter: it stays until Done, ended or not.
            .setContentIntent(open)
            .addAction(0, "Done", done)
            // Android 14 lets ongoing notifications be swiped away — that counts as Done.
            .setDeleteIntent(done)
            .build()
        // Untagged on purpose: SyncWorker.reconcileNotifications treats tags as
        // conversation keys and would cancel this one.
        runCatching { NotificationManagerCompat.from(c).notify(notificationId(id), n) }
    }

    private fun notificationId(zoneId: String) = zoneId.hashCode() or 0x2000_0000
}

/** Alarm at a zone's start/end → the notification (running/ended); the notification's Done → dismissed;
 *  boot / app update → re-arm from the cache. */
class ZoneAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ZoneAlerts.ACTION_START, ZoneAlerts.ACTION_END -> ZoneAlerts.showFromIntent(context, intent)
            // The POST runs in ZoneSyncWorker, not here: a receiver has ~10s and no retry.
            ZoneAlerts.ACTION_DONE -> intent.getStringExtra(ZoneAlerts.EXTRA_ID)?.let {
                ZoneAlerts.dismiss(context, it, intent.getLongExtra(ZoneAlerts.EXTRA_END, System.currentTimeMillis()))
            }
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> ZoneAlerts.rearmFromCache(context)
        }
    }
}

/** Pushes queued zone dismissals, then refetches zones + categories and re-arms the
 *  alarms — for when no CloudSession is loaded (Done from the notification, an FCM
 *  `zones_changed` with the app closed). Network-constrained, so a failed POST waits
 *  for connectivity; the queue also flushes on every in-app refreshZones. */
class ZoneSyncWorker(context: Context, params: androidx.work.WorkerParameters) :
    androidx.work.CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val token = com.inbox2.app.SecureStore.get(applicationContext, com.inbox2.app.SecureStore.MX_TOKEN)
            ?: return Result.success()
        val client = com.inbox2.app.cloud.CloudClient().apply { setToken(token) }
        val flushed = ZoneAlerts.flushDismissals(applicationContext, client)
        val now = System.currentTimeMillis()
        val iso = { ms: Long -> java.time.Instant.ofEpochMilli(ms).toString() }
        // Same window as CloudSession.refreshZones, so reconcile sees the same set.
        runCatching {
            val categories = client.zoneCategories()
            val zones = client.zones(iso(now - 86_400_000), iso(now + 14 * 86_400_000L))
            ZoneAlerts.reconcile(applicationContext, zones, categories)
        }
        return if (flushed) Result.success() else Result.retry()
    }

    companion object {
        fun enqueue(c: Context) {
            val req = androidx.work.OneTimeWorkRequestBuilder<ZoneSyncWorker>()
                .setConstraints(androidx.work.Constraints.Builder()
                    .setRequiredNetworkType(androidx.work.NetworkType.CONNECTED).build())
                .build()
            androidx.work.WorkManager.getInstance(c)
                .enqueueUniqueWork("inbox2-zones", androidx.work.ExistingWorkPolicy.REPLACE, req)
        }
    }
}
