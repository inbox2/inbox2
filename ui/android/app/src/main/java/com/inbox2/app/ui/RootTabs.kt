package com.inbox2.app.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.unit.IntOffset
import com.inbox2.app.ui.components.glowCapsule
import kotlinx.coroutines.launch
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.model.Conversation
import com.inbox2.app.model.ConversationAction
import com.inbox2.app.model.MailFolder
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.FloatingNavBar
import com.inbox2.app.ui.components.FolderDrawer
import com.inbox2.app.ui.components.NavItem
import com.inbox2.app.ui.screens.BridgeScreen
import com.inbox2.app.ui.screens.CalendarScreen
import com.inbox2.app.ui.screens.ComposeScreen
import com.inbox2.app.ui.screens.ComposePrefill
import com.inbox2.app.ui.screens.InboxScreen
import com.inbox2.app.ui.screens.ReaderScreen
import com.inbox2.app.ui.screens.UndoState
import com.inbox2.app.ui.screens.SettingsScreen

/**
 * App shell (iOS RootTabs): the active tab + a floating capsule nav (Inbox · Lore ·
 * compose center · Calendar · Settings). The folder drawer is a left slide-in overlay;
 * compose + the reader are pushed/sheet screens that hide the nav. Nav visibility mirrors
 * the iOS ChromeModel (pushed detail screen → hide nav).
 */
@Composable
fun RootTabs(engine: EngineModel, cloud: com.inbox2.app.cloud.CloudSession, themeManager: com.inbox2.app.theme.ThemeManager) {
    val p = theme
    val accounts by engine.accounts.collectAsState()
    val signedIn by cloud.user.collectAsState()
    var cloudLogin by remember { mutableStateOf(false) }
    val tabState = remember { mutableStateOf(0) }
    var tab by tabState
    var folder by remember { mutableStateOf(MailFolder.INBOX) }
    val showFoldersState = remember { mutableStateOf(false) }
    var showFolders by showFoldersState
    // Active inbox channel (account key), lifted from InboxScreen so the folder
    // drawer can show Meta channel sub-views vs mailboxes.
    var activeChannel by remember { mutableStateOf<String?>(null) }
    // The open address folder (its key) of the selected MX domain's Inbox; null = Inbox.
    var addressFolder by remember { mutableStateOf<String?>(null) }
    val folderTrees by cloud.folderTrees.collectAsState()
    val activeDomain = com.inbox2.app.model.AccountKey.domainFilter(activeChannel)
    val domainFolders = activeDomain?.let { folderTrees[it] }.orEmpty()
    val openAddressFolder = addressFolder?.let { k -> domainFolders.firstOrNull { it.key == k } }
    // Compose from an address folder you can reply as defaults From to that address.
    val composeFrom = openAddressFolder?.takeIf { it.canReply }?.address
    val readerState = remember { mutableStateOf<Conversation?>(null) }
    var reader by readerState
    val composeState = remember { mutableStateOf<ComposePrefill?>(null) }
    var compose by composeState
    // A meeting the Bridge voice agent drafted — surfaced as a prefilled create sheet on
    // the Calendar tab (the voice agent never saves; the user reviews + taps Save).
    var pendingEvent by remember { mutableStateOf<com.inbox2.app.ui.screens.EventDraftSeed?>(null) }
    // "Search mail" from a reader address token: pop the reader, hand the address to
    // the inbox's search field (consumed there).
    var inboxSearch by remember { mutableStateOf<String?>(null) }
    var addAccount by remember { mutableStateOf(false) }
    var modelPanel by remember { mutableStateOf(false) }
    var triagePanel by remember { mutableStateOf(false) }
    var rulesPanel by remember { mutableStateOf(false) }
    var themePanel by remember { mutableStateOf(false) }
    var activity by remember { mutableStateOf(false) }
    var prefPanel by remember { mutableStateOf(false) }
    var contactsPanel by remember { mutableStateOf(false) }
    var logsPanel by remember { mutableStateOf(false) }
    var devPanel by remember { mutableStateOf(false) }
    var connectedAccounts by remember { mutableStateOf(false) }
    var inbox2mx by remember { mutableStateOf(false) }
    var reconnect by remember { mutableStateOf<com.inbox2.app.oauth.OAuthProvider?>(null) }
    var reconnectHint by remember { mutableStateOf<String?>(null) }
    var reconnectOpen by remember { mutableStateOf(false) }
    var inboxEditing by remember { mutableStateOf(false) }
    var inboxSearching by remember { mutableStateOf(false) }
    // A tapped body link (in-app browser) / an invite banner's event (calendar detail).
    var browserUrl by remember { mutableStateOf<String?>(null) }
    val pendingEventKeyState = remember { mutableStateOf<String?>(null) }
    var pendingEventKey by pendingEventKeyState
    // Undo raised by a reader action, handed to the inbox (which owns the toast).
    var readerUndo by remember { mutableStateOf<UndoState?>(null) }
    var sendUndo by remember { mutableStateOf(false) }
    var game by remember { mutableStateOf(false) }
    // The Bridge voice session, opened from Lore's mic (voice is secondary since Lore
    // took tab slot 1; Android Auto keeps its own full Bridge screen).
    var bridge by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val ctx = androidx.compose.ui.platform.LocalContext.current

    RootStartupEffects(engine, cloud)

    // Fresh install: no connected mailbox and no signed-in domain → onboard instead of
    // the tabs. Adding an account (or signing in) swaps to the tabs automatically.
    if (accounts.isEmpty() && signedIn == null) {
        com.inbox2.app.ui.screens.OnboardingScreen(engine, cloud, onCloudSignIn = { cloudLogin = true })
        // Still allow the sign-in sheet over onboarding.
        AnimatedVisibility(cloudLogin, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
            com.inbox2.app.ui.screens.CloudLoginScreen(cloud, onClose = { cloudLogin = false })
        }
        return
    }

    RootEffects(engine, cloud, tabState, readerState, composeState, showFoldersState, pendingEventKeyState)

    val navItems = listOf(
        NavItem("tray.full", "Inbox"),
        NavItem("checklist", "Lore"),
        NavItem("calendar", "Calendar"),
        NavItem("gearshape", "Settings"),
    )

    // Every action fired inside the reader lands here — the reader doesn't touch the
    // inbox list, so this is where a filed/read thread gets the same side effects the
    // list's own applyAction gives it. Only a destructive action closes the reader:
    // mobile returns to the folder list rather than advancing into the next thread
    // (desktop advances). The inbox re-query reconciles once the write-back lands.
    fun advanceReader(convo: Conversation, action: ConversationAction) {
        // Clear the thread's notification now — the launcher badge is notification-
        // driven, so waiting for the next resume/sync leaves a stale count.
        if (action.clearsNotification)
            com.inbox2.app.notify.NotificationHelper.removeDelivered(ctx, listOf(convo.id))
        if (!action.removesRow) return
        // Suppress the filed row from the inbox's next re-query until the write-back
        // commits, and offer the same undo the swipe/menu path does — the toast lands
        // on the inbox we're returning to (the reader already fired the write-back).
        engine.markRemoved(listOf(convo.id))
        // ponytail: index 0 — undoRestore only unmarks + reverses, the re-query puts
        // the row back in its own order.
        if (action.reverse != null) readerUndo = UndoState(listOf(UndoState.Item(convo, 0)), action)
        reader = null
    }

    // Multi-select swaps the floating nav for the inbox's bulk bar in the same spot.
    val hideNav = reader != null || compose != null || addAccount || game || bridge || browserUrl != null || (tab == 0 && (inboxEditing || inboxSearching))

    // Android back: pop overlays/tabs in order before the system exits the app, so the
    // hardware/gesture back behaves like the screen stack rather than killing the app.
    val anyOverlay = cloudLogin || themePanel || activity || rulesPanel || modelPanel || triagePanel || addAccount ||
        prefPanel || contactsPanel || logsPanel || devPanel || reconnectOpen || connectedAccounts || inbox2mx
    androidx.activity.compose.BackHandler(enabled = anyOverlay || compose != null || reader != null || bridge || showFolders || tab != 0 || browserUrl != null) {
        when {
            browserUrl != null -> browserUrl = null
            cloudLogin -> cloudLogin = false
            themePanel -> themePanel = false
            activity -> activity = false
            rulesPanel -> rulesPanel = false
            modelPanel -> modelPanel = false
            triagePanel -> triagePanel = false
            addAccount -> addAccount = false
            prefPanel -> prefPanel = false
            contactsPanel -> contactsPanel = false
            logsPanel -> logsPanel = false
            devPanel -> devPanel = false
            connectedAccounts -> connectedAccounts = false
            inbox2mx -> inbox2mx = false
            reconnectOpen -> reconnectOpen = false
            compose != null -> compose = null
            reader != null -> reader = null
            bridge -> bridge = false
            showFolders -> showFolders = false
            tab != 0 -> tab = 0
        }
    }

    Box(Modifier.fillMaxSize().background(p.bgBase)) {
        Column(Modifier.fillMaxSize()) {
            // "You're in the zone" — sticky above every tab while a notify zone runs.
            if (signedIn != null) com.inbox2.app.ui.screens.ActiveZoneCard(cloud, onOpenCalendar = { reader = null; tab = 2 })
            Box(Modifier.weight(1f)) {
                when (tab) {
                    0 -> InboxScreen(engine, cloud, folder, addressFolder = openAddressFolder, onOpenFolders = { showFolders = true }, onOpenConversation = { reader = it }, onEditingChange = { inboxEditing = it }, onOpenActivity = { activity = true },
                        onCompose = { key -> compose = ComposePrefill(accountKey = key, fromEmailOverride = composeFrom) },
                        onOpenDraft = { d -> compose = ComposePrefill(accountKey = d.accountKey, to = d.to, cc = d.cc, bcc = d.bcc, subject = d.subject, body = d.body, savedDraftId = d.id) },
                        searchRequest = inboxSearch, onSearchConsumed = { inboxSearch = null },
                        onChannelChange = { key ->
                            if (key != activeChannel) addressFolder = null
                            activeChannel = key
                            // Keep the folder valid across the email↔Meta boundary: entering
                            // a Meta account from a mail folder selects its first sub-view;
                            // leaving one resets to Inbox.
                            val metaFolders = MailFolder.meta(accounts.firstOrNull { it.id == key }?.provider)
                            if (metaFolders != null) { if (!folder.isMeta) folder = metaFolders.first() }
                            else if (folder.isMeta) folder = MailFolder.INBOX
                        },
                        pendingUndo = readerUndo, onUndoConsumed = { readerUndo = null },
                        onForward = { compose = it }, onSearchingChange = { inboxSearching = it })
                    1 -> com.inbox2.app.ui.screens.LoreScreen(engine, cloud, onOpenConversation = { reader = it }, onOpenBridge = { bridge = true })
                    2 -> CalendarScreen(engine, seedEvent = pendingEvent, onSeedConsumed = { pendingEvent = null }, inboxAccountKey = activeChannel, cloud = cloud,
                        openEventKey = pendingEventKey, onOpenEventConsumed = { pendingEventKey = null })
                    else -> SettingsScreen(
                        engine,
                        onConnectedAccounts = { connectedAccounts = true }, onInbox2Mx = { inbox2mx = true },
                        onModelPanel = { modelPanel = true }, onTriagePanel = { triagePanel = true },
                        onRules = { rulesPanel = true }, onTheme = { themePanel = true },
                        onPreferences = { prefPanel = true }, onContacts = { contactsPanel = true },
                        onAppLogs = { logsPanel = true }, onDev = { devPanel = true },
                    )
                }
            }
        }

        // Floating nav (hidden while a detail screen is up)
        AnimatedVisibility(
            !hideNav,
            enter = slideInVertically { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
            modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = Space.s4),
        ) {
            FloatingNavBar(tab, navItems, onSelect = { tab = it }, onCompose = {
                // Seeded with the inbox's filtered account, like the inbox's own compose
                // button (a domain chip resolves to its org — the domain identity's key).
                compose = ComposePrefill(accountKey = if (com.inbox2.app.model.AccountKey.isDomain(activeChannel)) cloud.activeOrg.value else activeChannel,
                    fromEmailOverride = composeFrom)
            })
        }

        // Folder drawer overlay
        FolderDrawer(showFolders, folder, channelLabel = "", onSelect = { folder = it; addressFolder = null; showFolders = false }, onDismiss = { showFolders = false },
            provider = accounts.firstOrNull { it.id == activeChannel }?.provider,
            addressFolders = domainFolders, addressSelection = addressFolder,
            onSelectAddress = { folder = MailFolder.INBOX; addressFolder = it; showFolders = false },
            onSetFolderPref = { f, inbox, notify ->
                val org = cloud.activeOrg.value
                if (org != null && activeDomain != null) scope.launch { cloud.setFolderPref(org, activeDomain, f, inbox, notify) }
            })

        // The Bridge over Lore (sheet-like); compose / reader / the game draw above it.
        AnimatedVisibility(bridge, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
            BridgeScreen(engine, onLaunchGame = { game = true },
                onOpenCompose = { compose = it },
                onDraftEvent = { pendingEvent = it; bridge = false; tab = 2 },
                onClose = { bridge = false })
        }

        // Reader (pushed)
        AnimatedVisibility(reader != null, enter = fadeIn(), exit = fadeOut()) {
            reader?.let { c ->
                ReaderScreen(engine, cloud, c, onBack = { reader = null }, onReply = { prefill -> compose = prefill },
                    onSearchSender = { email -> reader = null; tab = 0; inboxSearch = email },
                    folder = folder, onAdvance = { c, a -> advanceReader(c, a) },
                    onSnoozed = { c ->
                        engine.markRemoved(listOf(c.id))
                        com.inbox2.app.notify.NotificationHelper.removeDelivered(ctx, listOf(c.id))
                        reader = null
                    },
                    onOpenUrl = { browserUrl = it },
                    onOpenEvent = { key -> reader = null; pendingEventKey = key; tab = 2 })
            }
        }

        // In-app browser over the reader (a tapped body link).
        AnimatedVisibility(
            browserUrl != null,
            enter = slideInVertically { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
        ) {
            browserUrl?.let { com.inbox2.app.ui.screens.InAppBrowserScreen(it, onClose = { browserUrl = null }) }
        }

        // Compose (sheet-like)
        AnimatedVisibility(
            compose != null,
            enter = slideInVertically { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
        ) {
            compose?.let { pre ->
                ComposeScreen(engine, cloud, pre, onClose = { compose = null }, onDomainSent = { sendUndo = true })
            }
        }

        // Domain send-undo toast ("Message sent · Undo") — reverts within the window.
        // Swipe it up to flick it away without waiting out the timer.
        if (sendUndo) {
            androidx.compose.runtime.LaunchedEffect(Unit) { kotlinx.coroutines.delay(6000); sendUndo = false }
            var drag by remember { mutableStateOf(0f) }
            Row(
                Modifier.align(Alignment.TopCenter).padding(top = Space.s6)
                    .offset { IntOffset(0, drag.coerceAtMost(0f).toInt()) }
                    .draggable(
                        orientation = Orientation.Vertical,
                        state = rememberDraggableState { delta -> drag = (drag + delta).coerceAtMost(0f) },
                        onDragStopped = { velocity ->
                            if (drag < -60f || velocity < -1000f) sendUndo = false else drag = 0f
                        },
                    )
                    .glowCapsule().padding(horizontal = Space.s4, vertical = Space.s2),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(Space.s3),
            ) {
                androidx.compose.material3.Text("Message sent", color = p.textPrimary, style = com.inbox2.app.theme.AppFont.sm)
                androidx.compose.material3.Text("Undo", color = p.accentViolet, style = com.inbox2.app.theme.AppFont.md,
                    modifier = Modifier.clickable(interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }, indication = null) {
                        sendUndo = false; scope.launch { cloud.undoLastSend() }
                    })
            }
        }

        // inbox2 mx sign-in (sheet-like)
        AnimatedVisibility(
            cloudLogin,
            enter = slideInVertically { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
        ) {
            com.inbox2.app.ui.screens.CloudLoginScreen(cloud, onClose = { cloudLogin = false })
        }

        // Add account (sheet-like)
        AnimatedVisibility(
            addAccount,
            enter = slideInVertically { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
        ) {
            com.inbox2.app.ui.screens.AddAccountScreen(engine, onClose = { addAccount = false })
        }

        // On-device AI model panel (sheet-like)
        AnimatedVisibility(
            modelPanel,
            enter = slideInVertically { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
        ) {
            com.inbox2.app.ui.screens.ModelPanelScreen(engine, onBack = { modelPanel = false })
        }

        // Triage & sync panel (sheet-like)
        AnimatedVisibility(
            triagePanel,
            enter = slideInVertically { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
        ) {
            com.inbox2.app.ui.screens.TriageSyncScreen(engine, onBack = { triagePanel = false })
        }

        // Auto-rules editor (sheet-like)
        AnimatedVisibility(
            rulesPanel,
            enter = slideInVertically { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
        ) {
            com.inbox2.app.ui.screens.RulesScreen(engine, onBack = { rulesPanel = false })
        }

        // Theme picker (sheet-like)
        AnimatedVisibility(themePanel, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
            com.inbox2.app.ui.screens.ThemePanelScreen(themeManager, onBack = { themePanel = false })
        }

        // Activity feed (sheet-like)
        AnimatedVisibility(activity, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
            com.inbox2.app.ui.screens.ActivityScreen(engine, onBack = { activity = false }, onOpenConversation = { activity = false; reader = it })
        }

        // Settings panels (sheet-like)
        AnimatedVisibility(prefPanel, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
            com.inbox2.app.ui.screens.PreferencesScreen(onBack = { prefPanel = false })
        }
        AnimatedVisibility(contactsPanel, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
            com.inbox2.app.ui.screens.ContactsScreen(engine, onBack = { contactsPanel = false })
        }
        AnimatedVisibility(logsPanel, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
            com.inbox2.app.ui.screens.AppLogsScreen(onBack = { logsPanel = false })
        }
        AnimatedVisibility(devPanel, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
            com.inbox2.app.ui.screens.DevScreen(engine, onBack = { devPanel = false }, themeManager = themeManager)
        }
        AnimatedVisibility(connectedAccounts, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
            com.inbox2.app.ui.screens.ConnectedAccountsScreen(engine, cloud, onBack = { connectedAccounts = false },
                onAddAccount = { addAccount = true }, onReconnect = { provider, hint -> reconnect = provider; reconnectHint = hint; reconnectOpen = true })
        }
        AnimatedVisibility(inbox2mx, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
            com.inbox2.app.ui.screens.Inbox2MxScreen(cloud, engine, onBack = { inbox2mx = false }, onCloudSignIn = { cloudLogin = true })
        }
        AnimatedVisibility(reconnectOpen, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
            com.inbox2.app.ui.screens.AddAccountScreen(engine, onClose = { reconnectOpen = false }, presetProvider = reconnect, presetLoginHint = reconnectHint,
                presetImap = reconnect == null)
        }

        // VOXEL STRIKE — full-screen game overlay launched from the Bridge (iOS NEON STRIKE parity).
        AnimatedVisibility(game, enter = fadeIn(), exit = fadeOut()) {
            com.inbox2.app.game.VoxelStrikeScreen(onClose = { game = false })
        }
    }
}
