package com.inbox2.app.notify

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.inbox2.app.MainActivity
import com.inbox2.app.R
import com.inbox2.app.data.InboxStore
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.model.CalendarEvent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * "Your meeting starts in 5 minutes" alarms, pre-scheduled with the OS (iOS MeetingAlarms).
 *
 * Every alarm is an `AlarmManager.setAlarmClock` handed to the system ahead of time —
 * exact without the exact-alarm permission, fires in Doze, shows the upcoming-alarm
 * icon — whose receiver posts a HIGH notification on its own channel with the 25 s
 * buzzer (`res/raw/meeting_alarm`, the same piezo pattern as iOS's .caf) on the ALARM
 * audio stream. The app's only job is keeping that schedule in step with the calendar:
 * `reconcile` runs on foreground, after each sync and whenever the settings change,
 * and the cached plan re-arms after a reboot (alarms die with it; iOS notifications
 * don't, hence the receiver).
 *
 * As alarm-like as Android lets a normal app be: the channel asks to bypass Do Not
 * Disturb (honoured when the user allows the app in DND settings); the ring/silent
 * switch and the alarm volume still apply.
 */
object MeetingAlarms {
    const val CHANNEL_ID = "inbox2_meeting_alarm"
    private const val PREFS = "inbox2_meeting_alarm"
    // Same keys as iOS.
    private const val KEY_ENABLED = "inbox2_meeting_alarm"
    private const val KEY_LEAD = "inbox2_meeting_alarm_lead"
    private const val KEY_MUTED = "inbox2_meeting_alarm_muted"
    private const val KEY_ARMED = "armed"
    private const val KEY_MY_EMAILS = "my_emails"
    internal const val ACTION_FIRE = "com.inbox2.app.MEETING_ALARM"
    const val EXTRA_EVENT_KEY = "calendarEventKey"
    private const val EXTRA_TITLE = "title"
    private const val EXTRA_BODY = "body"
    private const val TAG = "com.inbox2.alarms"

    val LEAD_CHOICES = listOf(1, 2, 5, 10, 15, 30)
    /** Only ever hold the nearest few dozen meetings; reconcile refills the tail. */
    // ponytail: fixed window — raise it only if someone books 32 meetings ahead and complains.
    private const val MAX_SCHEDULED = 32
    /** Rescan floor — `dataVersion` bumps on every mark-read too. */
    private const val MIN_INTERVAL_MS = 30_000L
    @Volatile private var lastReconcile = 0L

    /** Meetings the user silenced individually — observed so the event sheet re-renders. */
    val muted = MutableStateFlow<Set<String>>(emptySet())

    private fun prefs(c: Context) = c.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    fun enabled(c: Context) = prefs(c).getBoolean(KEY_ENABLED, false)
    fun leadMinutes(c: Context) = prefs(c).getInt(KEY_LEAD, 5).takeIf { it > 0 } ?: 5
    fun setEnabled(c: Context, on: Boolean) { prefs(c).edit().putBoolean(KEY_ENABLED, on).apply(); if (!on) cancelAll(c) }
    fun setLeadMinutes(c: Context, m: Int) = prefs(c).edit().putInt(KEY_LEAD, m).apply()
    fun isMuted(c: Context, eventKey: String) = eventKey in loadMuted(c)
    private fun loadMuted(c: Context): Set<String> =
        prefs(c).getStringSet(KEY_MUTED, null)?.toSet().orEmpty().also { muted.value = it }

    /** Silence or re-arm one meeting's alarm ("Cancel alarm" on the event sheet). */
    fun setMuted(c: Context, eventKey: String, on: Boolean) {
        val set = loadMuted(c).toMutableSet().apply { if (on) add(eventKey) else remove(eventKey) }
        prefs(c).edit().putStringSet(KEY_MUTED, set).apply()
        muted.value = set
        cancel(c, eventKey)
    }

    @Serializable
    data class Alarm(val eventKey: String, val title: String, val body: String, val fireAt: Long)

    /** Which meetings get an alarm (iOS MeetingAlarmPlan — pure, so the rules that decide
     *  whether the phone goes off are checkable). `events` = the agenda read, sorted by
     *  start, cancelled already excluded. At most `limit`, nearest first. */
    fun plan(events: List<CalendarEvent>, leadMinutes: Int, now: Long, muted: Set<String>, myEmails: Set<String>, limit: Int = MAX_SCHEDULED): List<Alarm> {
        val out = ArrayList<Alarm>()
        for (e in events) {
            val start = e.start ?: continue
            if (e.allDay || e.id in muted) continue
            val fireAt = start.time - leadMinutes * 60_000L
            // Only ever schedule ahead: a lead that has passed isn't an alarm, and firing
            // it anyway would re-nag on every foreground.
            if (fireAt <= now + 5_000) continue
            // A meeting you declined shouldn't wake you up.
            val mine = e.attendees.firstOrNull { (it.email ?: "").lowercase() in myEmails }
            if (mine?.responseStatus == "declined") continue
            var body = "Starts in $leadMinutes min · ${e.startTimeLabel}"
            e.location?.takeIf { it.isNotEmpty() && it.length <= 60 }?.let { body += " · $it" }
            out += Alarm(e.id, e.title, body, fireAt)
            if (out.size >= limit) break
        }
        return out
    }

    /** Bring the pending alarms in line with the calendar. Cheap enough to call freely —
     *  it throttles itself unless `force`. */
    suspend fun reconcile(c: Context, engine: EngineModel, force: Boolean = false) {
        val ctx = c.applicationContext
        if (!enabled(ctx)) { cancelAll(ctx); return }
        val now = System.currentTimeMillis()
        if (!force && now - lastReconcile < MIN_INTERVAL_MS) return
        lastReconcile = now
        val myEmails = engine.accounts.value.map { it.email.lowercase() }.toSet()
        prefs(ctx).edit().putStringSet(KEY_MY_EMAILS, myEmails).apply()
        val events = withContext(Dispatchers.IO) { engine.store.upcomingEvents(startOfTodayISO()) }
        apply(ctx, events, myEmails)
    }

    /** After a reboot / app update: the store on disk + the remembered addresses, no
     *  engine boot. */
    fun rearm(c: Context) {
        val ctx = c.applicationContext
        if (!enabled(ctx)) return
        val store = EngineModel.peek()?.store ?: InboxStore(File(File(ctx.filesDir, "inbox2"), "inbox2.db").path)
        val myEmails = prefs(ctx).getStringSet(KEY_MY_EMAILS, null).orEmpty()
        apply(ctx, store.upcomingEvents(startOfTodayISO()), myEmails, fromScratch = true)
    }

    private fun apply(ctx: Context, events: List<CalendarEvent>, myEmails: Set<String>, fromScratch: Boolean = false) {
        // Drop mutes for meetings that have fallen out of the window, so the set can't grow forever.
        val live = events.mapTo(HashSet()) { it.id }
        val muted = loadMuted(ctx)
        if (muted.any { it !in live }) {
            val kept = muted.intersect(live)
            prefs(ctx).edit().putStringSet(KEY_MUTED, kept).apply(); this.muted.value = kept
        }
        val wanted = plan(events, leadMinutes(ctx), System.currentTimeMillis(), muted, myEmails)
        val armed = if (fromScratch) emptyList() else loadArmed(ctx)
        val am = ctx.getSystemService(AlarmManager::class.java)
        // Stale = no longer wanted, or the meeting moved (compare fire times, so a
        // rescheduled meeting is re-armed rather than left behind).
        val wantedByKey = wanted.associateBy { it.eventKey }
        val stale = armed.filter { a -> wantedByKey[a.eventKey]?.fireAt != a.fireAt }
        stale.forEach { am.cancel(firePendingIntent(ctx, it.eventKey, null)) }
        val kept = armed.filter { it !in stale }.mapTo(HashSet()) { it.eventKey }
        var added = 0
        wanted.filter { it.eventKey !in kept }.forEach { a ->
            schedule(am, ctx, a)
            added++
        }
        saveArmed(ctx, wanted)
        Log.i(TAG, "meeting alarms: ${wanted.size} armed (+$added / -${stale.size})")
    }

    private fun cancel(ctx: Context, eventKey: String) {
        ctx.getSystemService(AlarmManager::class.java).cancel(firePendingIntent(ctx, eventKey, null))
        saveArmed(ctx, loadArmed(ctx).filter { it.eventKey != eventKey })
    }

    /** Forget every alarm we scheduled (master toggle off). */
    fun cancelAll(c: Context) {
        val ctx = c.applicationContext
        val armed = loadArmed(ctx)
        if (armed.isEmpty()) return
        val am = ctx.getSystemService(AlarmManager::class.java)
        armed.forEach { am.cancel(firePendingIntent(ctx, it.eventKey, null)) }
        saveArmed(ctx, emptyList())
        Log.i(TAG, "meeting alarms: cleared ${armed.size}")
    }

    /** Fire one alarm a few seconds from now, exactly as a real one would sound. */
    fun fireTest(c: Context) {
        val ctx = c.applicationContext
        val a = Alarm("", "Test alarm", "This is how a meeting alarm sounds.", System.currentTimeMillis() + 5_000)
        schedule(ctx.getSystemService(AlarmManager::class.java), ctx, a, key = "test")
    }

    /** Exact when the user allows it (Android 12+ gates `setAlarmClock` behind
     *  SCHEDULE_EXACT_ALARM — it throws SecurityException without the grant); otherwise
     *  `setAndAllowWhileIdle`, which still fires in Doze but may land minutes late. Same
     *  split as ZoneAlerts. */
    private fun schedule(am: AlarmManager, ctx: Context, a: Alarm, key: String = a.eventKey) {
        val pi = firePendingIntent(ctx, key, a)
        val exact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || am.canScheduleExactAlarms()
        if (exact && runCatching { am.setAlarmClock(AlarmManager.AlarmClockInfo(a.fireAt, openPendingIntent(ctx, a.eventKey)), pi) }.isSuccess) return
        am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, a.fireAt, pi)
    }

    /** Whether alarms can be exact right now; false means they may ring late. */
    fun exactAllowed(c: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S || c.applicationContext.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()

    /** What Android will actually let through, in words — only when something is wrong. */
    fun systemStatus(c: Context): String? {
        val ctx = c.applicationContext
        val mgr = ctx.getSystemService(NotificationManager::class.java)
        val blocked = ArrayList<String>()
        if (!NotificationManagerCompat.from(ctx).areNotificationsEnabled()) blocked += "notifications are off"
        if (!exactAllowed(ctx)) blocked += "exact alarms aren't allowed (they may ring a few minutes late)"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = mgr.getNotificationChannel(CHANNEL_ID)
            if (ch != null && ch.importance == NotificationManager.IMPORTANCE_NONE) blocked += "the Meeting alarms channel is off"
            if (mgr.currentInterruptionFilter != NotificationManager.INTERRUPTION_FILTER_ALL && ch?.canBypassDnd() != true)
                blocked += "Do Not Disturb is on"
        }
        return if (blocked.isEmpty()) null
            else "The alarm can't sound: ${blocked.joinToString(", ")}. Fix it in Android Settings › Notifications › inbox2."
    }

    // ── firing ──────────────────────────────────────────────────────────────

    internal fun fire(c: Context, i: Intent) {
        val ctx = c.applicationContext
        val key = i.getStringExtra(EXTRA_EVENT_KEY).orEmpty()
        if (key.isNotEmpty() && key in loadMuted(ctx)) return
        ensureChannel(ctx)
        val n = NotificationCompat.Builder(ctx, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher_monochrome)
            .setContentTitle(i.getStringExtra(EXTRA_TITLE) ?: "Meeting")
            .setContentText(i.getStringExtra(EXTRA_BODY))
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setSound(soundUri(ctx), AudioAttributes.USAGE_ALARM)   // pre-O; the channel carries it on O+
            .setAutoCancel(true)
            .setContentIntent(openPendingIntent(ctx, key))
            .build()
        runCatching { NotificationManagerCompat.from(ctx).notify(key.ifEmpty { "test" }, NOTIFICATION_ID, n) }
        if (key.isNotEmpty()) saveArmed(ctx, loadArmed(ctx).filter { it.eventKey != key })
    }

    private const val NOTIFICATION_ID = 0x3000_0001
    private fun soundUri(ctx: Context): Uri = Uri.parse("android.resource://${ctx.packageName}/${R.raw.meeting_alarm}")

    fun ensureChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = ctx.getSystemService(NotificationManager::class.java)
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        mgr.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Meeting alarms", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Rings before each meeting"
                setSound(soundUri(ctx), AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                setBypassDnd(true)
                enableVibration(true)
                setShowBadge(false)
            }
        )
    }

    // ── intents + cache ─────────────────────────────────────────────────────

    /** One PendingIntent per meeting (the key rides in the data URI, so `cancel` finds it). */
    private fun firePendingIntent(ctx: Context, eventKey: String, a: Alarm?): PendingIntent {
        val i = Intent(ctx, MeetingAlarmReceiver::class.java).setAction(ACTION_FIRE)
            .setData(Uri.parse("inbox2-meeting://$eventKey"))
        a?.let { i.putExtra(EXTRA_EVENT_KEY, it.eventKey).putExtra(EXTRA_TITLE, it.title).putExtra(EXTRA_BODY, it.body) }
        return PendingIntent.getBroadcast(ctx, 0, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** Tap → the calendar, straight to the event (MainActivity.consumeNotificationTap). */
    private fun openPendingIntent(ctx: Context, eventKey: String): PendingIntent =
        PendingIntent.getActivity(ctx, eventKey.hashCode(),
            Intent(ctx, MainActivity::class.java).setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                .apply { if (eventKey.isNotEmpty()) putExtra(EXTRA_EVENT_KEY, eventKey) },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun loadArmed(ctx: Context): List<Alarm> =
        prefs(ctx).getString(KEY_ARMED, null)?.let { runCatching { Json.decodeFromString<List<Alarm>>(it) }.getOrNull() }.orEmpty()
    private fun saveArmed(ctx: Context, list: List<Alarm>) =
        prefs(ctx).edit().putString(KEY_ARMED, Json.encodeToString(list)).apply()

    private fun startOfTodayISO(): String {
        val cal = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        return SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US).format(cal.time)
    }
}

/** The alarm → its notification; boot / app update → re-arm from the store. */
class MeetingAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            MeetingAlarms.ACTION_FIRE -> MeetingAlarms.fire(context, intent)
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                val pending = goAsync()
                Thread { runCatching { MeetingAlarms.rearm(context) }; pending.finish() }.start()
            }
        }
    }
}
