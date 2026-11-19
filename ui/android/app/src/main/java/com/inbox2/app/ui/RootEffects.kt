package com.inbox2.app.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.model.Conversation
import com.inbox2.app.ui.screens.ComposePrefill

// The app shell's side effects (split out of RootTabs.kt, 2026-10-18; RootTabs keeps the
// layout). Two groups, because the onboarding early-return in RootTabs sits between them:
// [RootStartupEffects] runs even while onboarding, [RootEffects] only once the tabs show.

/** Startup wiring that must run before/without the tabs: open-tracking mirror, the
 *  AI/NLU config + Jev key, and the org's triage taxonomy. */
@Composable
internal fun RootStartupEffects(engine: EngineModel, cloud: com.inbox2.app.cloud.CloudSession) {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val accounts by engine.accounts.collectAsState()
    val signedIn by cloud.user.collectAsState()
    // Mirror cloud-synced per-channel open-tracking config into the local engine at
    // launch (re-runs when sign-in settles or the account list loads). LaunchedEffect
    // runs in a coroutine, so this network call never blocks startup (docs/Open-Tracking.md).
    LaunchedEffect(signedIn != null, accounts.size) {
        if (signedIn != null) engine.mirrorChannelTracking(cloud)
    }
    // Push the AI/NLU config to the engine at app startup (iOS Inbox2App `.task(id:)`),
    // so the background triage worker classifies/summarizes on the user's chosen model
    // even if the Bridge is never opened. The Bridge re-pushes on open and the model
    // panel re-pushes on change; this is the always-on baseline.
    LaunchedEffect(Unit) {
        val prefs = com.inbox2.app.engine.VoicePrefs(ctx)
        engine.setAiConfig(com.inbox2.app.engine.nluBridgeConfig(engine, prefs))
        // Jev triage key (docs/Triage.md) — keystore read off the main thread.
        val jevKey = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            com.inbox2.app.SecureStore.get(ctx, com.inbox2.app.SecureStore.TYPESAFE_KEY)
        }
        engine.setJevKey(jevKey)
    }

    // Cloud-linked: the org's triage label names (MX rows name custom labels) and its
    // classifiable Spaces as the local classifier's taxonomy (docs/Triage.md "Spaces").
    val orgs by cloud.orgs.collectAsState()
    val activeOrg by cloud.activeOrg.collectAsState()
    LaunchedEffect(orgs) { if (orgs.isNotEmpty()) cloud.loadTriageLabelNames() }
    LaunchedEffect(activeOrg) {
        val orgId = activeOrg ?: return@LaunchedEffect
        val spaces = cloud.spaces(orgId) ?: return@LaunchedEffect
        val taxonomy = org.json.JSONArray()
        spaces.filter { it.classify && !it.slug.isNullOrEmpty() }.forEach { s ->
            taxonomy.put(org.json.JSONObject().put("slug", s.slug).put("name", s.name)
                .put("description", s.description.orEmpty().ifBlank { s.name })
                .put("not_for", s.notFor.orEmpty()))
        }
        engine.setSpaceTaxonomy(taxonomy.toString())
    }
}

/** Effects of the running shell: the ongoing-card/alarm refresh, notification + alarm
 *  taps, "Send to inbox2" shares and the zone refresh. They navigate through the handed
 *  state handles (tab / reader / compose / folder drawer / pending event). */
@Composable
internal fun RootEffects(
    engine: EngineModel, cloud: com.inbox2.app.cloud.CloudSession,
    tabState: MutableState<Int>, readerState: MutableState<Conversation?>, composeState: MutableState<ComposePrefill?>,
    showFoldersState: MutableState<Boolean>, pendingEventKeyState: MutableState<String?>,
) {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val signedIn by cloud.user.collectAsState()
    var tab by tabState
    var reader by readerState
    var compose by composeState
    var showFolders by showFoldersState
    var pendingEventKey by pendingEventKeyState
    // The ongoing newest-unread card tracks every local change (iOS refreshes the Mail
    // Live Activity from EngineModel.perform + CloudSession.markChanged).
    val liveDataVersion by engine.dataVersion.collectAsState()
    val liveRevision by cloud.revision.collectAsState()
    LaunchedEffect(liveDataVersion, liveRevision) {
        com.inbox2.app.notify.NotificationHelper.refreshOngoing(ctx.applicationContext, engine, cloud)
        // Keep the pre-scheduled meeting alarms in step with the calendar (throttled inside).
        com.inbox2.app.notify.MeetingAlarms.reconcile(ctx.applicationContext, engine)
    }
    // A tapped meeting alarm → the Calendar tab on that event.
    val alarmTap by com.inbox2.app.notify.NotificationHelper.tappedEvent.collectAsState()
    LaunchedEffect(alarmTap) {
        val key = alarmTap ?: return@LaunchedEffect
        reader = null; compose = null; showFolders = false
        pendingEventKey = key; tab = 2
        com.inbox2.app.notify.NotificationHelper.tappedEvent.value = null
    }

    // A tapped new-mail notification (iOS NotificationManager.pendingConversationKey):
    // look the conversation up and push the reader, dropping whatever covers it.
    val notifTap by com.inbox2.app.notify.NotificationHelper.tappedConversation.collectAsState()
    LaunchedEffect(notifTap) {
        val key = notifTap ?: return@LaunchedEffect
        // Resolve + navigate FIRST, then clear the flow. Nulling it before the await would
        // re-key this effect and cancel the in-flight lookup, dropping the open (iOS 193a2530).
        val convo = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { engine.store.conversation(key) }
        if (convo != null) {
            tab = 0
            compose = null
            showFolders = false
            reader = convo
        }
        com.inbox2.app.notify.NotificationHelper.tappedConversation.value = null
    }

    // "Send to inbox2" from another app (MainActivity.consumeShare): read the shared
    // content-URI bytes off the main thread, then open compose with them pre-loaded as
    // attachments (shared text/URL lands in the body). Same URI→bytes path the in-compose
    // file picker uses.
    val pendingShare by com.inbox2.app.share.ShareTarget.pending.collectAsState()
    LaunchedEffect(pendingShare) {
        val share = pendingShare ?: return@LaunchedEffect
        com.inbox2.app.share.ShareTarget.pending.value = null
        val atts = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            share.uris.mapNotNull { uri ->
                runCatching {
                    val cr = ctx.contentResolver
                    val name = cr.query(uri, null, null, null, null)?.use { c ->
                        val i = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                        if (i >= 0 && c.moveToFirst()) c.getString(i) else null
                    } ?: uri.lastPathSegment ?: "attachment"
                    val mime = cr.getType(uri) ?: "application/octet-stream"
                    val bytes = cr.openInputStream(uri)?.use { it.readBytes() } ?: ByteArray(0)
                    com.inbox2.app.ui.screens.PrefillAttachment(name, mime, bytes)
                }.getOrNull()
            }
        }
        tab = 0
        reader = null
        showFolders = false
        compose = ComposePrefill(
            subject = share.subject ?: "",
            body = share.text ?: "",
            initialAttachments = atts,
        )
    }
    // Zones (cloud-only): load categories + the upcoming window and arm the zone
    // alarms once signed in (MainActivity's resume hook refreshes them after).
    LaunchedEffect(signedIn != null) { cloud.refreshZones() }
    // FCM `zones_changed` (edited or dismissed on another device): while this collects,
    // FcmService leaves the refetch to us instead of enqueuing ZoneSyncWorker.
    LaunchedEffect(Unit) {
        com.inbox2.app.notify.ZoneAlerts.remoteChanged.collect { if (it > 0) cloud.zonesChanged() }
    }
}
