package com.inbox2.app.ui.screens

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.tween
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.ui.draw.alpha
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.AnchoredDraggableState
import androidx.compose.foundation.gestures.DraggableAnchors
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.anchoredDraggable
import androidx.compose.foundation.gestures.animateTo
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.ui.draw.drawBehind
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.border
import com.inbox2.app.ui.components.pageGround
import com.inbox2.app.ui.components.groovePanel
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.inbox2.app.engine.AccountStatusValue
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.model.*
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.ChannelColor
import com.inbox2.app.theme.colorHex
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.ProcessingHairline
import com.inbox2.app.ui.components.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Inbox list (iOS InboxListView): header, search, channels row, filter pills, list
 *  with swipe + undo toast, long-press multi-select + a bulk bar that replaces the nav,
 *  Move-to-Inbox in restore folders, and an Outbox view. Non-UI state (rows/query/
 *  filter, selection, undo, pending-removal reconciliation, action routing) lives in
 *  [InboxState]; this composable keeps layout + callbacks. */
@OptIn(ExperimentalFoundationApi::class, androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun InboxScreen(
    engine: EngineModel,
    cloud: com.inbox2.app.cloud.CloudSession,
    folder: MailFolder,
    onOpenFolders: () -> Unit,
    onOpenConversation: (Conversation) -> Unit,
    onEditingChange: (Boolean) -> Unit = {},
    onOpenActivity: () -> Unit = {},
    /** New-message button in the header — opens a blank compose seeded with the
     *  account key of the channel currently being viewed (null on Unified). */
    onCompose: (String?) -> Unit = {},
    onOpenDraft: (com.inbox2.app.engine.SavedDraft) -> Unit = {},
    searchRequest: String? = null,
    onSearchConsumed: () -> Unit = {},
    onChannelChange: (String?) -> Unit = {},
    /** Report the visible, ordered conversation list up to the shell so the reader can
     *  advance to the next thread after a destructive action (web reading-pane parity). */
    onRowsChange: (List<Conversation>) -> Unit = {},
    /** Undo raised elsewhere (a reader action) — the inbox owns the toast. */
    pendingUndo: UndoState? = null,
    onUndoConsumed: () -> Unit = {},
    /** Row-menu Forward: a ready "Fwd:" draft for the shell to open (iOS forwardRow). */
    onForward: (ComposePrefill) -> Unit = {},
    /** The search field is open — the shell hides the floating nav (iOS ChromeModel.searching). */
    onSearchingChange: (Boolean) -> Unit = {},
) {
    val p = theme
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()
    val focusManager = androidx.compose.ui.platform.LocalFocusManager.current
    val dataVersion by engine.dataVersion.collectAsState()
    val accounts by engine.accounts.collectAsState()
    val activeOrg by cloud.activeOrg.collectAsState()
    val cloudOrgs by cloud.orgs.collectAsState()
    val state = rememberInboxState(engine, cloud)
    // Report the active channel up so the folder drawer (owned by the shell) can
    // show Meta channel sub-views vs mailboxes.
    LaunchedEffect(state.channel) { onChannelChange(state.channel) }

    var menuFor by remember { mutableStateOf<String?>(null) }
    var menuAt by remember { mutableStateOf(androidx.compose.ui.geometry.Offset.Zero) }
    val editing = state.editing
    val isDomainChannel = state.isDomainChannel

    // In the unified inbox, the channel a conversation belongs to — drives the
    // row avatar's corner badge so pooled channels are distinguishable. null in a
    // single-channel view (the channel is implied by the active tab).
    fun channelBadgeFor(convo: Conversation): com.inbox2.app.ui.components.ChannelBadgeInfo? {
        if (state.channel != null) return null
        // MX rows carry the ORG id as their account key, but a domain chip is keyed by
        // its own `dom_…` workspace id — an id match never lands, which is why MX
        // threads showed no badge at all. Resolve the chip from the domain in the
        // thread's own addresses; off-domain recipients fall back to the first chip.
        if (convo.isDomain) {
            val org = cloudOrgs.firstOrNull { it.id == convo.accountKey } ?: return null
            val addrs = "${convo.toAddress} ${convo.fromAddress}".lowercase()
            if (org.domains.isEmpty()) {
                return com.inbox2.app.ui.components.ChannelBadgeInfo(
                    seed = org.id, label = org.domain ?: org.name,
                    order = cloudOrgs.map { it.id }, avatarURL = org.iconUrl, provider = null,
                )
            }
            val dom = org.domains.firstOrNull { addrs.contains("@" + it.name.lowercase()) }
                ?: org.domains.first()
            return com.inbox2.app.ui.components.ChannelBadgeInfo(
                seed = dom.id, label = dom.name, order = org.domains.map { it.id },
                avatarURL = dom.iconUrl ?: if (dom.name == org.domain) org.iconUrl else null,
                provider = null,
            )
        }
        val acct = accounts.firstOrNull { it.id == convo.accountKey } ?: return null
        return com.inbox2.app.ui.components.ChannelBadgeInfo(
            seed = convo.accountKey,
            label = channelDisplayLabel(acct.email),
            order = accounts.map { it.id },
            avatarURL = acct.avatarURL,
            provider = acct.provider,
        )
    }

    // Read aloud from the row menu (iOS InboxListView leads with it): the same
    // controller as the reader — stored summary + the 5 s voice-triage window —
    // without leaving the inbox.
    val voicePrefs = remember { com.inbox2.app.engine.VoicePrefs(ctx) }
    val speaker = remember { com.inbox2.app.audio.Speaker(ctx, engine, voicePrefs) }
    val readAloud = remember {
        com.inbox2.app.audio.ReadAloudController(
            engine, voicePrefs, speaker, com.inbox2.app.audio.TriageListener(ctx), scope,
        )
    }
    val readPhase by readAloud.phase.collectAsState()
    DisposableEffect(Unit) { onDispose { readAloud.stop(); speaker.shutdown() } }

    LaunchedEffect(editing) { onEditingChange(editing) }
    LaunchedEffect(folder) { state.selected = emptySet() }
    // Keep the shell's copy of the ordered list current so reader advance-to-next can
    // pick the neighbour of the thread it just filed.
    LaunchedEffect(state.rows) { onRowsChange(state.rows) }
    // Restarting this effect per keystroke (cancelling the prior delay) is the debounce.
    LaunchedEffect(state.query) {
        // Emptying the field (here or via the ✕) dismisses the keyboard.
        if (state.query.isEmpty()) focusManager.clearFocus()
        state.runSearchDebounce()
    }
    val cloudRevision by cloud.revision.collectAsState()
    // `activeOrg` is a key so the unified merge re-fires once orgs populate after
    // sign-in/restore (the MX half is empty until then).
    LaunchedEffect(dataVersion, cloudRevision, folder, state.channel, state.filter, state.effectiveQuery, state.domainView, activeOrg) {
        state.reload(folder)
    }
    // A triage result landed: patch the visible row in place — no store requery,
    // no full recompose. Only a triage-scoped view reloads (a new label can add
    // a row there).
    val triagePatch by engine.triagePatch.collectAsState()
    LaunchedEffect(triagePatch) {
        triagePatch?.let { if (!state.applyTriagePatch(it, folder)) state.reload(folder) }
    }
    LaunchedEffect(state.undo) { state.expireUndo() }
    LaunchedEffect(pendingUndo) { pendingUndo?.let { state.undo = it; onUndoConsumed() } }

    if (folder == MailFolder.OUTBOX) { OutboxView(engine); return }

    val restoreAction = folderRestoreAction(folder)
    val syncing by engine.syncing.collectAsState()
    val triage by engine.triage.collectAsState()
    var searchOpen by remember { mutableStateOf(false) }
    // "Search mail" handed over from a reader address token: open the search field
    // pre-filled with that address.
    LaunchedEffect(searchRequest) {
        searchRequest?.let { state.query = it; searchOpen = true; onSearchConsumed() }
    }
    LaunchedEffect(searchOpen) { onSearchingChange(searchOpen) }
    androidx.compose.runtime.DisposableEffect(Unit) { onDispose { onSearchingChange(false) } }
    val localDrafts = if (folder == MailFolder.DRAFTS && !isDomainChannel)
        remember(dataVersion, folder) { com.inbox2.app.engine.DraftStore(ctx).all() } else emptyList()

    Box(Modifier.fillMaxSize().background(p.bgBase)) {
        // Short crossfade between the two list trees so the check circles don't pop.
        Crossfade(editing, animationSpec = tween(150), label = "editmode") { inEdit ->
        if (inEdit) {
            Column(Modifier.fillMaxSize()) {
                // Edit-mode header: Cancel / "n Selected" / Select All
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = Space.s4).padding(top = Space.s3, bottom = Space.s2),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("Cancel", color = p.accentViolet, style = AppFont.md,
                        modifier = Modifier.noRippleClickable { state.selected = emptySet() })
                    Spacer(Modifier.weight(1f))
                    Text("${state.selected.size} Selected", color = p.textPrimary, style = AppFont.title3)
                    Spacer(Modifier.weight(1f))
                    Text("All", color = p.accentViolet, style = AppFont.md,
                        modifier = Modifier.noRippleClickable { state.selected = state.rows.map { it.id }.toSet() })
                }
                LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(horizontal = Space.s4, vertical = Space.s1)) {
                    items(state.rows, key = { it.id }) { convo ->
                        SelectableRow(convo, convo.id in state.selected, channelBadge = channelBadgeFor(convo), modifier = rowAnim()) {
                            state.selected = if (convo.id in state.selected) state.selected - convo.id else state.selected + convo.id
                        }
                    }
                    item { Spacer(Modifier.height(110.dp)) }
                }
            }
        } else {
            // Everything (header, search, channels, pills) is part of the body scroll,
            // matching iOS — the upper section scrolls away with the list. Pull-to-refresh
            // kicks a sync.
            val listState = androidx.compose.foundation.lazy.rememberLazyListState()
            // Collapse as soon as the big title starts leaving (iOS CollapseOnScroll: > 12pt).
            val collapsed by remember { androidx.compose.runtime.derivedStateOf {
                listState.firstVisibleItemIndex > 0 || listState.firstVisibleItemScrollOffset > 36
            } }
            // Groovebox: the list floats over the guidebook grid (iOS parity); the header
            // strips stay on solid bars so they read.
            Box(Modifier.fillMaxSize().then(if (p.groove != null) Modifier.pageGround() else Modifier)) {
            androidx.compose.material3.pulltorefresh.PullToRefreshBox(
                isRefreshing = syncing, onRefresh = { engine.sync() }, modifier = Modifier.fillMaxSize(),
            ) {
            LazyColumn(Modifier.fillMaxSize(), state = listState, contentPadding = PaddingValues(top = Space.s1, bottom = 0.dp)) {
                item {
                    // Header: hamburger + INBOX (uppercase, muted) + search / sync / bell.
                    Row(
                        Modifier.fillMaxWidth().grooveBar().padding(horizontal = Space.s4).padding(top = Space.s1, bottom = Space.s2),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(SfIcon.vector("line.3.horizontal"), "Mailboxes", tint = p.textSecondary,
                            modifier = Modifier.size(24.dp).noRippleClickable { onOpenFolders() })
                        Spacer(Modifier.width(Space.s3))
                        Text(folder.title.uppercase(), color = p.textSecondary, style = AppFont.title,
                            letterSpacing = androidx.compose.ui.unit.TextUnit(0.5f, androidx.compose.ui.unit.TextUnitType.Sp))
                        if (state.unreadCount > 0) Text(" (${state.unreadCount})", color = p.accentViolet, style = AppFont.title3,
                            modifier = Modifier.padding(start = Space.s1))
                        Spacer(Modifier.weight(1f))
                        HeaderIcon("magnifyingglass") { searchOpen = !searchOpen }
                        HeaderIcon("arrow.clockwise", spinning = syncing) { engine.sync() }
                        HeaderIcon("square.and.pencil") {
                            // A domain chip is keyed by `dom_…`; compose keys a domain
                            // identity by the org id, so resolve it here.
                            onCompose(if (state.isDomainChannel) cloud.activeOrg.value else state.channel)
                        }
                        HeaderIcon("bell", tint = p.accentViolet) { onOpenActivity() }
                    }
                }
                if (searchOpen) item {
                    Row(
                        Modifier.grooveBar().padding(horizontal = Space.s4, vertical = Space.s1).fillMaxWidth()
                            .clip(RoundedCornerShape(Radius.full)).background(p.bgInput)
                            .padding(horizontal = Space.s3, vertical = Space.s2 + 2.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        // The leading glyph doubles as the loading indicator: it swaps
                        // to a spinner while a debounced search is in flight.
                        if (state.searching) CircularProgressIndicator(
                            modifier = Modifier.size(16.dp), strokeWidth = 2.dp, color = p.textTertiary)
                        else Icon(SfIcon.vector("magnifyingglass"), "Search", tint = p.textTertiary, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(Space.s2))
                        Box(Modifier.weight(1f)) {
                            if (state.query.isEmpty()) Text("Search mail", color = p.textTertiary, style = AppFont.sm)
                            BasicTextField(state.query, { state.query = it }, textStyle = AppFont.sm.copy(color = p.textPrimary),
                                singleLine = true, cursorBrush = SolidColor(p.accentViolet),
                                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = ImeAction.Search))
                        }
                        // Clearing also drops focus so the keyboard dismisses.
                        if (state.query.isNotEmpty()) Icon(SfIcon.vector("xmark.circle.fill"), "Clear", tint = p.textTertiary,
                            modifier = Modifier.size(18.dp).noRippleClickable { state.query = ""; focusManager.clearFocus() })
                    }
                }
                item {
                    Row(
                        Modifier.fillMaxWidth().grooveBar().horizontalScroll(rememberScrollState())
                            .padding(horizontal = Space.s4, vertical = Space.s2),
                        horizontalArrangement = Arrangement.spacedBy(Space.s4),
                    ) {
                        // Unified = all channels, so nothing is "unselected" — keep every chip
                        // at full opacity. Once an individual channel is selected, fade the
                        // others back so the active one stands out (iOS ChannelsRow).
                        val fadeInactive = state.channel != null
                        ChannelChip("Unified", null, state.channel == null, isUnified = true, online = true, fadeInactive = fadeInactive) { state.channel = null }
                        accounts.forEach { a ->
                            ChannelChip(channelDisplayLabel(a.email), a, state.channel == a.id, avatarURL = a.avatarURL, order = accounts.map { it.id }, online = a.status == AccountStatusValue.CONNECTED, fadeInactive = fadeInactive) { state.channel = a.id }
                        }
                        // The signed-in team pool: one chip PER domain (an org owns many
                        // equal domains), mirroring the web per-domain workspace tabs. Each
                        // chip is keyed by the domain's `dom_…` id; the icon precedence
                        // matches web: the domain's own icon, else the org icon on its
                        // primary domain, else the name's initial.
                        cloudOrgs.firstOrNull { it.id == activeOrg }?.let { org ->
                            if (org.domains.isEmpty()) {
                                ChannelChip(org.domain ?: org.name, null, state.channel == org.id, icon = "building.2.fill", fadeInactive = fadeInactive) { state.channel = org.id }
                            } else {
                                val order = org.domains.map { it.id }
                                org.domains.forEach { dom ->
                                    val avatar = dom.iconUrl ?: if (dom.name == org.domain) org.iconUrl else null
                                    ChannelChip(dom.name, null, state.channel == dom.id, avatarURL = avatar, order = order, seed = dom.id, fadeInactive = fadeInactive) { state.channel = dom.id }
                                }
                            }
                        }
                    }
                }
                // The well's header strip: the filter tabs flush on top of the rows, with a
                // one-line count of what's loaded on the right (iOS columnHeader). No card
                // of rows follows it when a page-level state renders instead, so it closes
                // the well itself.
                item {
                    val (options, selection, onSelect) = if (isDomainChannel) {
                        // Team-pool views appear only for a specific domain chip.
                        Triple(listOf("All", "Mine", "Unassigned", "Unread"), state.domainView, { it: String -> state.domainView = it })
                    } else {
                        // Unified shows only the universal tabs (All / Unread); the triage
                        // quadrant view (Triaged) is offered only for a specific channel chip.
                        val filters = if (state.channel == null) listOf(InboxFilter.ALL, InboxFilter.UNREAD)
                            else InboxFilter.entries.toList()
                        Triple(filters.map { it.label }, state.filter.label,
                            { sel: String -> state.filter = InboxFilter.entries.first { it.label == sel } })
                    }
                    val headerCloses = state.searchPending || state.loadError != null || state.rows.isEmpty()
                    val unreadLoaded = state.rows.count { it.unread }
                    val summary = if (unreadLoaded > 0) "${state.rows.size} · $unreadLoaded unread" else "${state.rows.size}"
                    ColumnHeader(options, selection, onSelect, summary,
                        Modifier.padding(top = Space.s1).wellRow(first = true, last = headerCloses, header = !headerCloses))
                }

                // Local drafts (DraftStore) at the top of the Drafts folder; tap to resume.
                if (folder == MailFolder.DRAFTS && !isDomainChannel) {
                    items(localDrafts, key = { "draft_" + it.id }) { d ->
                        Column(
                            Modifier.fillMaxWidth().grooveBar().padding(horizontal = Space.s4, vertical = Space.s2)
                                .noRippleClickable { onOpenDraft(d) }
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(d.subject.ifBlank { "(no subject)" }, color = p.textPrimary, style = AppFont.ui(14, androidx.compose.ui.text.font.FontWeight.Medium), maxLines = 1, modifier = Modifier.weight(1f))
                                InboxTag("Draft", p.accentAmber)
                            }
                            Text(d.preview, color = p.textTertiary, style = AppFont.xs, maxLines = 1)
                        }
                    }
                }

                if (state.searchPending) {
                    // Text in the search field but no search applied yet — don't show the
                    // normal inbox behind it; it reads as bogus results (iOS).
                    item {
                        Box(Modifier.fillMaxWidth().padding(top = Space.s8).groovePanel(), contentAlignment = Alignment.Center) {
                            EmptyState(
                                "magnifyingglass",
                                if (state.searchTooShort) "Keep typing" else "Searching…",
                                if (state.searchTooShort) "Search needs at least $MIN_SEARCH_CHARS characters."
                                else "Looking for “${state.query.trim()}”…",
                            )
                        }
                    }
                } else if (state.loadError != null) {
                    item { InboxErrorState(state.loadError ?: "") { scope.launch { state.reload(folder) } } }
                } else if (state.rows.isEmpty()) {
                    item {
                        Box(Modifier.fillMaxWidth().padding(top = Space.s8).groovePanel(), contentAlignment = Alignment.Center) {
                            EmptyState(
                                if (state.effectiveQuery.isNotEmpty()) "magnifyingglass" else "tray",
                                if (state.effectiveQuery.isNotEmpty()) "No results" else "All clear",
                                if (state.effectiveQuery.isNotEmpty()) "No conversations match “${state.effectiveQuery}”."
                                else "Nothing in ${if (!isDomainChannel && state.filter != InboxFilter.ALL) state.filter.label.lowercase() else folder.title} right now.",
                            )
                        }
                    }
                } else {
                    itemsIndexed(state.rows, key = { _, it -> it.id }) { index, convo ->
                        Box(rowAnim().wellRow(first = false, last = index == state.rows.lastIndex)) {
                            SwipeRow(
                                convo = convo,
                                restoreAction = restoreAction,
                                modifier = Modifier.padding(horizontal = Space.s4),
                                channelBadge = channelBadgeFor(convo),
                                onArchive = { state.applyAction(convo, restoreAction ?: ConversationAction.Archive) },
                                onTrash = { state.applyAction(convo, ConversationAction.Trash) },
                                onToggleRead = {
                                    state.applyAction(convo, if (convo.unread) ConversationAction.MarkRead else ConversationAction.MarkUnread)
                                },
                                onOpen = { onOpenConversation(convo) },
                                onLongPress = { pos -> menuFor = convo.id; menuAt = pos },
                                onAvatarLongPress = { state.selected = setOf(convo.id) },
                            )
                            ConvActionMenu(
                                expanded = menuFor == convo.id,
                                onDismiss = { menuFor = null },
                                convo = convo,
                                offset = with(LocalDensity.current) { DpOffset(menuAt.x.toDp(), menuAt.y.toDp()) },
                                onAction = { state.applyAction(convo, it) },
                                onSnooze = if (convo.isDomain) { { w -> state.snooze(convo, w.date()) } } else null,
                                onForward = {
                                    // The latest message (cloud thread for domain, else the store)
                                    // → a Fwd: draft; attachments download in the composer.
                                    scope.launch {
                                        val last = if (convo.isDomain) cloud.messages(convo.accountKey, convo.id).lastOrNull()
                                            else withContext(Dispatchers.IO) { engine.store.messages(convo.id).lastOrNull() }
                                        onForward(forwardPrefill(engine, convo, last, domainEmails(convo, cloud)))
                                    }
                                },
                                onReadAloud = {
                                    readAloud.stop()
                                    readAloud.start(convo) { action -> state.applyAction(convo, action) }
                                },
                            )
                        }
                    }
                    item { Spacer(Modifier.height(110.dp)) }
                }
            }
            // Sticky collapsed bar — fades in once the big header scrolls past (iOS collapsedBar).
            androidx.compose.animation.AnimatedVisibility(
                collapsed, modifier = Modifier.align(Alignment.TopCenter),
                enter = androidx.compose.animation.fadeIn(tween(200)), exit = androidx.compose.animation.fadeOut(tween(200)),
            ) {
                Row(
                    Modifier.fillMaxWidth().background(p.bgBase)
                        .drawBehind { drawRect(p.borderSubtle, topLeft = androidx.compose.ui.geometry.Offset(0f, size.height - 1f), size = androidx.compose.ui.geometry.Size(size.width, 1f)) }
                        .padding(horizontal = Space.s4, vertical = Space.s2),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(SfIcon.vector("line.3.horizontal"), "Mailboxes", tint = p.textSecondary,
                        modifier = Modifier.size(20.dp).noRippleClickable { onOpenFolders() })
                    Spacer(Modifier.width(Space.s2 + 2.dp))
                    Text(folder.title.uppercase(), color = p.textSecondary, style = AppFont.title3,
                        letterSpacing = androidx.compose.ui.unit.TextUnit(0.5f, androidx.compose.ui.unit.TextUnitType.Sp))
                    if (state.unreadCount > 0) Text(" (${state.unreadCount})", color = p.textSecondary.copy(alpha = 0.7f),
                        style = AppFont.ui(15, androidx.compose.ui.text.font.FontWeight.SemiBold))
                    Spacer(Modifier.weight(1f))
                    HeaderIcon("magnifyingglass") { searchOpen = !searchOpen }
                    HeaderIcon("arrow.clockwise", spinning = syncing) { engine.sync() }
                    HeaderIcon("square.and.pencil") { onCompose(if (state.isDomainChannel) cloud.activeOrg.value else state.channel) }
                    HeaderIcon("bell", tint = p.accentViolet) { onOpenActivity() }
                }
            }
            }
            }
        }
        }

        // Hands-free filing window opened by row-menu Read aloud (reader shows
        // the same pill under its header).
        if (readPhase == com.inbox2.app.audio.ReadAloudController.Phase.LISTENING) {
            Text(
                "Listening. Trash or archive?", color = p.accentViolet, style = AppFont.xs,
                modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 120.dp),
            )
        }

        // Bulk action bar (replaces the nav, mirroring it) — InboxChrome.kt.
        if (editing) BulkActionBar(Modifier.align(Alignment.BottomCenter), restoreAction) { state.bulk(it) }

        // Ambient processing indicator: the triage worker is classifying /
        // summarizing in the background — a gradient hairline along the bottom
        // edge of the list while the queue is non-empty (iOS parity).
        if (triage.isActive) ProcessingHairline(Modifier.align(Alignment.BottomCenter))

        // Undo toast — drops down from the top under the header. Swipe it up to
        // flick it away without waiting out the timer.
        state.undo?.let { u ->
            var drag by remember(u) { mutableStateOf(0f) }
            Box(Modifier.align(Alignment.TopCenter).padding(top = 120.dp)
                .offset { IntOffset(0, drag.coerceAtMost(0f).toInt()) }
                .draggable(
                    orientation = Orientation.Vertical,
                    state = rememberDraggableState { delta -> drag = (drag + delta).coerceAtMost(0f) },
                    onDragStopped = { velocity ->
                        if (drag < -60f || velocity < -1000f) state.undo = null else drag = 0f
                    },
                )) {
                // Resolve the channel avatar only when every undone row shares one
                // external account (mirrors iOS undoToastChannel).
                val undoChannel = u.items.map { it.convo.accountKey }.toSet().singleOrNull()
                    ?.let { key -> accounts.firstOrNull { it.id == key } }
                    ?.let { acct ->
                        com.inbox2.app.ui.components.ChannelBadgeInfo(
                            seed = acct.id,
                            label = channelDisplayLabel(acct.email),
                            order = accounts.map { it.id },
                            avatarURL = acct.avatarURL,
                        )
                    }
                UndoToast(u, channel = undoChannel) { state.undoRestore(u) }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
/** Short fade (+ default placement slide) for rows filed, restored, or reordered. */
private fun LazyItemScope.rowAnim() = Modifier.animateItem(fadeInSpec = tween(150), fadeOutSpec = tween(150))

@Composable
private fun SelectableRow(
    convo: Conversation, checked: Boolean,
    channelBadge: com.inbox2.app.ui.components.ChannelBadgeInfo? = null,
    modifier: Modifier = Modifier,
    onToggle: () -> Unit,
) {
    val p = theme
    Row(
        modifier.fillMaxWidth()
            // Groovebox: a checked row is a solid fill inside a lavender ring — no wash, no rail.
            .then(p.groove?.takeIf { checked }?.let { g ->
                val shape = RoundedCornerShape(Radius.lg)
                Modifier.background(g.rowSelected, shape).border(1.5.dp, g.rowRing, shape)
            } ?: Modifier)
            .combinedClickable(
            interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onToggle),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Crossfade(checked, animationSpec = tween(120), label = "check") { on ->
            Icon(
                SfIcon.vector(if (on) "checkmark.circle.fill" else "person.crop.circle"),
                // Checked controls are teal under Groovebox.
                null, tint = if (on) (if (p.groove != null) p.accentSuccess else p.accentViolet) else p.textTertiary, modifier = Modifier.size(22.dp).padding(start = 2.dp),
            )
        }
        Spacer(Modifier.width(Space.s2))
        Box(Modifier.weight(1f)) { ConversationRow(convo, channelBadge = channelBadge) }
    }
}

@Composable
private fun ChannelChip(
    label: String, account: com.inbox2.app.engine.AccountRow?, selected: Boolean,
    isUnified: Boolean = false, avatarURL: String? = null, order: List<String> = emptyList(),
    online: Boolean = false, icon: String? = null, seed: String? = null, fadeInactive: Boolean = false, onClick: () -> Unit,
) {
    val p = theme
    val chipAlpha by animateFloatAsState(if (selected || !fadeInactive) 1f else 0.75f, label = "chipfade")
    Column(
        Modifier.width(64.dp).alpha(chipAlpha).noRippleClickable { onClick() },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        ChannelAvatar(label, seed ?: account?.id ?: "unified", order, avatarURL, icon = icon, isUnified = isUnified, selected = selected, online = online, provider = account?.provider, size = 56.dp)
        Text(label, style = AppFont.xs3, color = if (selected) p.textPrimary else p.textTertiary,
            maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
    }
}

/** The local mailbox read failed (disk I/O, corruption). Distinct from "All clear" so a
 *  failed read isn't mistaken for no mail; shows the raw engine detail and a retry
 *  (iOS inboxErrorState). */
@Composable
private fun InboxErrorState(detail: String, onRetry: () -> Unit) {
    val p = theme
    Column(
        Modifier.fillMaxWidth().padding(Space.s8),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Space.s3),
    ) {
        Icon(SfIcon.vector("externaldrive.badge.exclamationmark"), null, tint = p.accentDanger, modifier = Modifier.size(46.dp))
        Text("Couldn’t load your inbox", color = p.textPrimary, style = AppFont.lg)
        Text("This phone couldn't read your mail from storage. Your mail is safe on the server.",
            color = p.textTertiary, style = AppFont.sm, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        Text(detail, color = p.textMuted, style = AppFont.xs, maxLines = 2,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        Text("Try again", color = p.accentViolet, style = AppFont.ui(14, androidx.compose.ui.text.font.FontWeight.SemiBold),
            modifier = Modifier.padding(top = Space.s2).noRippleClickable { onRetry() })
    }
}

/** Groovebox: a solid page-coloured strip over the grid so header text reads. */
@Composable
private fun Modifier.grooveBar(): Modifier {
    val p = theme
    return if (p.groove != null) background(p.bgBase) else this
}

/**
 * A row of the recessed inbox "well" (iOS cardBG): the rows sit in one card on the page —
 * `bgPanel` with a continuous scrim groove down both sides, rounded on the first/last
 * row, a short dark wash falling in under the top lip, the faint inner bevel hairline,
 * and an inset divider between rows. Light themes drop the groove — the list is a
 * borderless light card on the grey canvas. `header` = the column header's own bottom
 * edge, full-width, not a divider between two rows.
 */
@Composable
private fun Modifier.wellRow(first: Boolean, last: Boolean, header: Boolean = false): Modifier {
    val p = theme
    val r = if (p.groove != null) Radius.xl else 8.dp   // Groovebox: rounder panel
    val shape = RoundedCornerShape(
        topStart = if (first) r else 0.dp, topEnd = if (first) r else 0.dp,
        bottomStart = if (last) r else 0.dp, bottomEnd = if (last) r else 0.dp,
    )
    val groove = if (p.isDark) com.inbox2.app.theme.scrim(0.45f) else androidx.compose.ui.graphics.Color.Transparent
    val bevel = com.inbox2.app.theme.bevel(0.03f)
    val divider = if (header) (if (p.isDark) groove else p.borderSubtle) else p.borderSubtle
    return this.padding(horizontal = if (p.groove != null) Space.s3 else Space.s2).clip(shape).background(p.bgPanel).drawBehind {
        val one = 1.dp.toPx()
        // Light falls *into* the well: a short dark gradient under the top lip.
        if (first && p.isDark) drawRect(
            androidx.compose.ui.graphics.Brush.verticalGradient(listOf(com.inbox2.app.theme.scrim(0.26f), androidx.compose.ui.graphics.Color.Transparent), endY = 5.dp.toPx()),
            size = androidx.compose.ui.geometry.Size(size.width, 5.dp.toPx()))
        // Continuous groove sides, carried around the corners on the rounded rows.
        val stroke = androidx.compose.ui.graphics.drawscope.Stroke(one * 2)
        val radius = androidx.compose.ui.geometry.CornerRadius(r.toPx())
        drawRoundRect(groove, cornerRadius = radius, style = stroke)
        drawRoundRect(bevel, cornerRadius = radius, style = androidx.compose.ui.graphics.drawscope.Stroke(one))
        if (header || !last) drawRect(
            divider,
            topLeft = androidx.compose.ui.geometry.Offset(if (header) 0f else Space.s5.toPx(), size.height - one),
            size = androidx.compose.ui.geometry.Size(size.width, one))
    }
}

/** The well's header strip (iOS columnHeader): scrolling filter tabs with a 1.5dp accent
 *  underline on the active one, and the loaded count at the right. */
@Composable
private fun ColumnHeader(options: List<String>, selection: String, onSelect: (String) -> Unit, summary: String, modifier: Modifier = Modifier) {
    val p = theme
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Row(
            Modifier.weight(1f).horizontalScroll(rememberScrollState()).padding(horizontal = Space.s4),
            horizontalArrangement = Arrangement.spacedBy(Space.s4),
        ) {
            options.forEach { opt ->
                val active = opt == selection
                Box(Modifier.noRippleClickable { onSelect(opt) }) {
                    Text(opt, color = if (active) p.textPrimary else p.textTertiary,
                        style = AppFont.ui(12, if (active) androidx.compose.ui.text.font.FontWeight.SemiBold else androidx.compose.ui.text.font.FontWeight.Medium),
                        modifier = Modifier.padding(vertical = Space.s2 + 2.dp))
                    Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(1.5.dp)
                        .background(if (active) p.accentViolet else androidx.compose.ui.graphics.Color.Transparent))
                }
            }
        }
        Text(summary, color = p.textMuted, style = AppFont.ui(11, androidx.compose.ui.text.font.FontWeight.Medium),
            modifier = Modifier.padding(end = Space.s4))
    }
}
