package com.inbox2.app

import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.lifecycleScope
import com.inbox2.app.engine.EngineModel
import kotlinx.coroutines.launch
import com.inbox2.app.theme.Inbox2Theme
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.RootTabs

class MainActivity : ComponentActivity() {
    private val requestNotif = registerForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission()
    ) { /* best-effort; mail still syncs without it */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Engine boot is heavy (30MB .so load, SQLite open, keystore, FFI) — run it off
        // the main thread; the composition keeps LaunchSplash up until engineState fills.
        lifecycleScope.launch(kotlinx.coroutines.Dispatchers.Default) {
            val engine = EngineModel.get(applicationContext)
            // New mail → local notifications (server-free), + a periodic background sync.
            engine.setNewMessageSink { payload ->
                com.inbox2.app.notify.NotificationHelper.postNewMessage(applicationContext, payload)
            }
            com.inbox2.app.notify.NotificationHelper.ensureChannel(applicationContext)
            com.inbox2.app.notify.SyncWorker.schedule(applicationContext)
            // Register this device for API push (idempotent; deferred until signed in).
            com.inbox2.app.fcm.FcmTokenManager.ensureRegistered(applicationContext)
            engineState.value = engine
            // Notification-button actions taken while the process was dead.
            com.inbox2.app.notify.NotificationActions.drain(applicationContext)
        }
        if (Build.VERSION.SDK_INT >= 33) requestNotif.launch(android.Manifest.permission.POST_NOTIFICATIONS)
        consumeNotificationTap(intent)
        consumeShare(intent)
        setContent { Root() }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        consumeNotificationTap(intent)
        consumeShare(intent)
    }

    override fun onResume() {
        super.onResume()
        // Clear tray notifications for mail read/dealt-with since we were last open
        // (here or on another device) — keeps the launcher badge honest. Off the main
        // thread: it reads SQLite + enumerates active notifications.
        lifecycleScope.launch(kotlinx.coroutines.Dispatchers.Default) {
            com.inbox2.app.notify.SyncWorker.afterSync(applicationContext, EngineModel.get(applicationContext))
        }
    }

    override fun onStop() {
        super.onStop()
        // App no longer visible: release the resident on-device LLM so the suspended
        // process isn't OOM-killed holding it (iOS background-unload parity). The next
        // generation rebuilds it; unload is a no-op if a generation is in flight.
        EngineModel.peek()?.unloadOnDeviceModel()
    }

    /** A tapped new-mail notification carries its conversation key; hand it to the
     *  composition (RootTabs opens the thread). Covers both the cold launch (onCreate
     *  intent) and the running-app tap (onNewIntent via SINGLE_TOP). */
    private fun consumeNotificationTap(intent: android.content.Intent?) {
        // A meeting alarm opens its event instead (Calendar tab → detail sheet).
        intent?.getStringExtra(com.inbox2.app.notify.MeetingAlarms.EXTRA_EVENT_KEY)?.let { key ->
            intent.removeExtra(com.inbox2.app.notify.MeetingAlarms.EXTRA_EVENT_KEY)
            com.inbox2.app.notify.NotificationHelper.tappedEvent.value = key
            return
        }
        // Local notifications carry EXTRA_CONVERSATION_KEY; a tapped FCM tray
        // notification (visible MX push) delivers its data map as raw extras.
        val key = intent?.getStringExtra(com.inbox2.app.notify.NotificationHelper.EXTRA_CONVERSATION_KEY)
            ?: intent?.getStringExtra("conversation_id")
            ?: return
        intent?.removeExtra(com.inbox2.app.notify.NotificationHelper.EXTRA_CONVERSATION_KEY)
        intent?.removeExtra("conversation_id")
        com.inbox2.app.notify.NotificationHelper.tappedConversation.value = key
    }

    /** "Send to inbox2" from another app: stash the shared text/subject + file URIs for
     *  the composition to open compose with (RootTabs reads the URI bytes off-thread).
     *  Covers the cold launch (onCreate) and the running-app share (onNewIntent via
     *  singleTop). Clears the action so a config-change re-create can't re-fire it. */
    private fun consumeShare(intent: android.content.Intent?) {
        intent ?: return
        val action = intent.action
        if (action != android.content.Intent.ACTION_SEND && action != android.content.Intent.ACTION_SEND_MULTIPLE) return
        val text = intent.getStringExtra(android.content.Intent.EXTRA_TEXT)
        val subject = intent.getStringExtra(android.content.Intent.EXTRA_SUBJECT)
        val uris: List<android.net.Uri> = if (action == android.content.Intent.ACTION_SEND_MULTIPLE) {
            val list: ArrayList<android.net.Uri>? =
                if (Build.VERSION.SDK_INT >= 33)
                    intent.getParcelableArrayListExtra(android.content.Intent.EXTRA_STREAM, android.net.Uri::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableArrayListExtra(android.content.Intent.EXTRA_STREAM)
            list ?: emptyList()
        } else {
            val u: android.net.Uri? =
                if (Build.VERSION.SDK_INT >= 33)
                    intent.getParcelableExtra(android.content.Intent.EXTRA_STREAM, android.net.Uri::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableExtra(android.content.Intent.EXTRA_STREAM)
            listOfNotNull(u)
        }
        if (uris.isEmpty() && text.isNullOrBlank()) return
        intent.action = null
        com.inbox2.app.share.ShareTarget.pending.value =
            com.inbox2.app.share.PendingShare(subject, text, uris)
    }
}

/** Last return-to-foreground sync (elapsedRealtime); see the ON_RESUME effect below. */
private var lastForegroundSync = -60_000L

/** The engine, delivered once the off-main boot in onCreate finishes (null until then).
 *  Process-scoped like the EngineModel singleton, so a re-created activity skips the wait. */
private val engineState = kotlinx.coroutines.flow.MutableStateFlow<EngineModel?>(null)

@Composable
private fun Root() {
    val ctx = LocalContext.current
    val engine by engineState.collectAsState()
    val cloud = remember {
        com.inbox2.app.cloud.CloudSession(ctx.applicationContext).also { com.inbox2.app.notify.NotificationHelper.liveCloud = it }
    }
    val themeManager = remember { com.inbox2.app.theme.ThemeManager(ctx.applicationContext) }
    androidx.compose.runtime.LaunchedEffect(Unit) { cloud.restore() }
    // Re-pull /account on every foreground so a domain added/removed elsewhere shows
    // up without a relaunch (no realtime channel on mobile). The first ON_RESUME is a
    // no-op — restore() hasn't signed in yet, so refreshAccount() returns early.
    val cloudScope = androidx.compose.runtime.rememberCoroutineScope()
    androidx.lifecycle.compose.LifecycleEventEffect(androidx.lifecycle.Lifecycle.Event.ON_RESUME) {
        // Zones too: re-arms the zone alarms (lost on reboot) and refreshes the in-app card.
        cloudScope.launch { cloud.refreshAccount(); cloud.refreshZones() }
        // A backgrounded app doesn't sync — SyncWorker's floor is 15 min and Doze can
        // stretch it — so returning to it showed mail deleted/read on another device
        // until you pulled to refresh. Sync the local channels + re-query the domain
        // lists. ponytail: fixed 60s throttle, not a real last-sync timestamp — app
        // flipping (and activity re-creation) must not hammer Gmail, which 403s on its
        // per-minute quota. Process-scoped so a rotation doesn't reset it.
        val now = android.os.SystemClock.elapsedRealtime()
        val e = engine // null during the cold-start boot window — that launch just synced anyway
        if (e != null && now - lastForegroundSync > 60_000) {
            lastForegroundSync = now
            e.sync()
            cloud.refreshViews()
        }
    }
    val systemDark = androidx.compose.foundation.isSystemInDarkTheme()
    var showSplash by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(true) }
    // Splash drops when the engine is ready — floored at 300ms (1.6s under Groovebox) so it doesn't flash,
    // capped at 4s so a wedged engine boot never strands it.
    val splashShownAt = remember { android.os.SystemClock.elapsedRealtime() }
    androidx.compose.runtime.LaunchedEffect(engine == null) {
        if (engine == null) kotlinx.coroutines.delay(4_000)
        else {
            // Groovebox holds the splash until its scene has drawn itself in.
            val floor = if (themeManager.appearance == com.inbox2.app.theme.Appearance.GROOVEBOX ||
                com.inbox2.app.theme.AppIconOption.current(ctx) == com.inbox2.app.theme.AppIconOption.GROOVEBOX)
                com.inbox2.app.ui.screens.GROOVEBOX_SPLASH_MS else 300
            kotlinx.coroutines.delay((floor - (android.os.SystemClock.elapsedRealtime() - splashShownAt)).coerceAtLeast(0))
        }
        showSplash = false
    }
    val palette = themeManager.palette(systemDark)
    // Pin the system-bar icon style to the app palette (a Light/Atelier app on a dark
    // system would otherwise get light status-bar icons over a pale page).
    val activity = ctx as? ComponentActivity
    androidx.compose.runtime.LaunchedEffect(palette.isDark) {
        activity?.enableEdgeToEdge(
            statusBarStyle = if (palette.isDark) androidx.activity.SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
                else androidx.activity.SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
            navigationBarStyle = if (palette.isDark) androidx.activity.SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
                else androidx.activity.SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
        )
    }
    Inbox2Theme(palette = palette) {
        androidx.compose.foundation.layout.Box(
            Modifier.fillMaxSize().background(theme.bgBase).windowInsetsPadding(WindowInsets.systemBars)
        ) {
            engine?.let { RootTabs(it, cloud, themeManager) }
        }
        // Cold-launch splash: dark cover + brand mark, fades out once.
        androidx.compose.animation.AnimatedVisibility(
            showSplash, enter = androidx.compose.animation.fadeIn(),
            exit = androidx.compose.animation.fadeOut(androidx.compose.animation.core.tween(450)),
        ) { com.inbox2.app.ui.screens.LaunchSplash() }
    }
}
