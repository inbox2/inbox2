package com.inbox2.app.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.inbox2.app.cloud.CloudSession
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.engine.LoreSentRef
import com.inbox2.app.engine.McpJson
import com.inbox2.app.engine.isMemberDone
import com.inbox2.app.engine.LoreBucket
import com.inbox2.app.engine.LoreEntityRef
import com.inbox2.app.engine.LoreGroup
import com.inbox2.app.engine.LoreHandledGroup
import com.inbox2.app.engine.LorePageRef
import com.inbox2.app.engine.LoreText
import com.inbox2.app.engine.LoreToday
import com.inbox2.app.engine.LoreTodo
import com.inbox2.app.engine.TriageLabel
import com.inbox2.app.engine.TriageLabelNames
import com.inbox2.app.model.AccountKey
import com.inbox2.app.model.Conversation
import com.inbox2.app.model.ConversationAction
import com.inbox2.app.model.MailAddress
import com.inbox2.app.model.MailFolder
import com.inbox2.app.model.RelativeTime
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.ThemePalette
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.AvatarRing
import com.inbox2.app.ui.components.EmptyState
import com.inbox2.app.ui.components.PillButton
import com.inbox2.app.ui.components.SfIcon
import com.inbox2.app.ui.components.noRippleClickable
import kotlinx.coroutines.launch

/** The desktop sidebar's views, as a chip bar (docs/plans/lore.md §3; iOS LoreTab). */
private enum class LoreTab(val title: String) { TODAY("Today"), WAITING("Waiting"), HANDLED("Handled"), HISTORY("History") }

/** A screen Lore pushes over itself (iOS LoreRoute). */
private sealed interface LoreRoute {
    data class Entity(val ref: LoreEntityRef) : LoreRoute
    data class Page(val orgId: String, val page: LorePageRef) : LoreRoute
}

/** Lore asks for more MX pages than the inbox's first: an old open task must not drop off Today. */
private const val TODAY_PAGES = 20
private const val HISTORY_PAGES = 2

/**
 * Lore — tab slot 1 (docs/plans/lore.md §6; replaced the Bridge there; iOS LoreView).
 * A Next-up card, then checklists by bucket, grouped (an invoice and its reminder are
 * one row). Ticking a box (or swiping) archives the thread through the inbox's own
 * action path ([EngineModel.performRouted] → local engine or MX); a refused action
 * puts the rows back. "Handled for you" only suggests. Views: Today / Waiting /
 * Handled / History, a search, organizations and the person's C:\Lore pages; an
 * org/person page and a read-only notes page push over the list. The small voice orb
 * opens the Bridge.
 *
 * Rows are the unified inbox's read ([InboxState.reload]: every channel + every MX
 * org's mirrored pool), narrowed to threads that carry a Lore triage label.
 */
@Composable
fun LoreScreen(
    engine: EngineModel,
    cloud: CloudSession,
    onOpenConversation: (Conversation) -> Unit,
    onOpenBridge: () -> Unit,
) {
    val p = theme
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val state = rememberInboxState(engine, cloud)
    val history = rememberInboxState(engine, cloud)   // recently archived Lore threads
    var todos by remember { mutableStateOf<List<LoreTodo>>(emptyList()) }
    var pages by remember { mutableStateOf<Pair<String, List<LorePageRef>>?>(null) }
    var tab by remember { mutableStateOf(LoreTab.TODAY) }
    var query by remember { mutableStateOf("") }
    var expanded by remember { mutableStateOf<Set<String>>(emptySet()) }   // open groups / Handled lists
    var routes by remember { mutableStateOf<List<LoreRoute>>(emptyList()) }
    val dataVersion by engine.dataVersion.collectAsState()
    val cloudRevision by cloud.revision.collectAsState()
    val orgs by cloud.orgs.collectAsState()
    val syncing by engine.syncing.collectAsState()
    var refresh by remember { mutableStateOf(0) }
    var loaded by remember { mutableStateOf(false) }   // the first read finished
    var historyLoaded by remember { mutableStateOf(false) }   // the first archive read finished
    var sendTo by remember { mutableStateOf<Conversation?>(null) }   // the Send to… sheet's item
    var sent by remember { mutableStateOf<Map<String, LoreSentRef>>(emptyMap()) }   // what Send to… made, for the row's chip
    suspend fun reload() {
        state.reload(MailFolder.INBOX, TODAY_PAGES, labeledOnly = true)
        todos = engine.loreTodos()
        runCatching { sent = McpJson.sentList(engine.mcp { it.loreSentListJson() }).reversed().associateBy { it.itemKey } }   // newest wins
        loaded = true
        history.reload(MailFolder.ARCHIVE, HISTORY_PAGES, labeledOnly = true)
        historyLoaded = true
        // Always assign: a signed-out session or another org must not keep stale page titles.
        pages = cloud.lorePages()
    }
    LaunchedEffect(dataVersion, cloudRevision, orgs, refresh) { reload() }

    val today = remember(state.rows, query) { LoreToday.build(state.rows.filter { LoreText.matches(it, query) }) }
    val openLore = remember(state.rows) { state.rows.filter { LoreBucket.forLabel(it.triageLabel) != null && !it.loreDone } }
    val archived = remember(history.rows, state.rows) {
        (history.rows + state.rows.filter { it.loreDone && history.rows.none { h -> h.id == it.id } })
            .filter { LoreBucket.forLabel(it.triageLabel) != null }
            .sortedByDescending { RelativeTime.parse(it.updatedAt)?.time ?: 0L }
    }
    val next = today.nextGroup
    val handledCount = today.handled.sumOf { it.items.size }

    /** Done = archive (or the Handled group's action): rows leave now, one call per
     *  account; a refused call stops hiding its rows and re-reads, so they come back. */
    fun done(list: List<Conversation>, action: ConversationAction = ConversationAction.Archive) {
        if (list.isEmpty()) return
        val ids = list.mapTo(HashSet()) { it.id }
        // A personal bucket on a shared domain is this member's tick: the thread stays
        // in the inbox read, so the row is flipped rather than removed.
        val (mine, rest) = list.partition { it.isMemberDone }
        val mineIds = mine.mapTo(HashSet()) { it.id }
        val restIds = rest.mapTo(HashSet()) { it.id }
        state.rows = state.rows.mapNotNull { c -> if (c.id in restIds) null else if (c.id in mineIds) c.copy(loreDone = true) else c }
        engine.markRemoved(restIds)
        if (action.clearsNotification) com.inbox2.app.notify.NotificationHelper.removeDelivered(ctx, restIds)
        // A tick archives real mail and a stray tap is easy: offer the inbox's undo for five seconds.
        val shown = if (rest.isEmpty()) ConversationAction.LoreDone else action
        if (shown.reverse != null) state.undo = UndoState(
            list.mapIndexed { i, c -> UndoState.Item(c, i, if (c.isMemberDone) ConversationAction.LoreUndone else null) }, shown)
        (mine.groupBy { it.accountKey to ConversationAction.LoreDone as ConversationAction } + rest.groupBy { it.accountKey to action }).forEach { (key, group) ->
            val (acct, act) = key
            scope.launch {
                if (engine.performRouted(cloud, acct, group.map { it.id }, act.verb)) return@launch
                engine.unmarkRemoved(group.map { it.id })
                if (state.undo?.items?.any { it.convo.id in ids } == true) state.undo = null
                refresh++
            }
        }
    }
    LaunchedEffect(state.undo) { state.expireUndo() }
    sendTo?.let { c -> SendToSheet(c, engine, onDismiss = { sendTo = null }, onSent = { sent = sent + (it.itemKey to it) }) }
    fun putBack(c: Conversation) {
        if (c.loreDone) {
            state.rows = state.rows.map { if (it.id == c.id) it.copy(loreDone = false) else it }
            scope.launch { engine.performRouted(cloud, c.accountKey, listOf(c.id), ConversationAction.LoreUndone.verb); refresh++ }
            return
        }
        history.rows = history.rows.filterNot { it.id == c.id }
        scope.launch { engine.performRouted(cloud, c.accountKey, listOf(c.id), ConversationAction.Unarchive.verb); refresh++ }
    }
    fun complete(t: LoreTodo) {
        todos = todos.filterNot { it.id == t.id }
        scope.launch { engine.completeLoreTodo(t.id) }
    }
    fun toggle(id: String) { expanded = if (id in expanded) expanded - id else expanded + id }
    fun push(r: LoreRoute) { routes = routes + r }
    val rowActions = RowActions(cloud = cloud, onOpen = onOpenConversation, onDone = { done(it) }, onToggle = ::toggle,
        isOpen = { it in expanded }, onEntity = { push(LoreRoute.Entity(it)) }, onSendTo = { sendTo = it }, sent = sent)

    BackHandler(enabled = routes.isNotEmpty()) { routes = routes.dropLast(1) }
    when (val top = routes.lastOrNull()) {
        is LoreRoute.Entity -> {
            LoreEntityScreen(engine, cloud, top.ref, openLore, archived, onBack = { routes = routes.dropLast(1) },
                onOpen = onOpenConversation, onEntity = { push(LoreRoute.Entity(it)) }, onDone = { done(it) })
            return
        }
        is LoreRoute.Page -> {
            LorePageScreen(cloud, top.orgId, top.page, onBack = { routes = routes.dropLast(1) })
            return
        }
        null -> Unit
    }

    // Plain bgBase, not the Groovebox grid: a to-do list needs a quiet page.
    Box(Modifier.fillMaxSize().background(p.bgBase)) {
        androidx.compose.material3.pulltorefresh.PullToRefreshBox(
            isRefreshing = syncing, onRefresh = { engine.sync(); refresh++ },
            modifier = Modifier.fillMaxSize(),
        ) {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 140.dp)) {
                item {
                    Row(Modifier.padding(horizontal = Space.s4).padding(top = Space.s1, bottom = Space.s3),
                        verticalAlignment = Alignment.CenterVertically) {
                        Text("LORE", color = p.textSecondary, style = AppFont.title)
                        val open = today.open + todos.size
                        if (open > 0) Text(" ($open)", color = p.textSecondary.copy(alpha = 0.7f), style = AppFont.title2)
                    }
                }
                item(key = "tabs") {
                    TabBar(tab, waiting = today.sections.first { it.bucket == LoreBucket.WAITING }.items.size, handled = handledCount,
                        query = query, onTab = {
                            tab = it
                            // Handled starts unfolded, but each group can still collapse.
                            if (it == LoreTab.HANDLED) expanded = expanded + today.handled.map { g -> "handled:${g.label.raw}" }
                        },
                        onQuery = { q -> query = q; if (q.isNotEmpty() && (tab == LoreTab.WAITING || tab == LoreTab.HANDLED)) tab = LoreTab.TODAY })
                }
                // A failed local read shows on every tab, even when MX rows loaded (and Next-up
                // shows). History also reads the archive, so its loader's error counts there.
                val readError = if (tab == LoreTab.HISTORY) history.loadError ?: state.loadError else state.loadError
                if (readError != null) item(key = "readError") {
                    Row(Modifier.padding(horizontal = Space.s4).padding(bottom = Space.s3).fillMaxWidth()
                        .clip(RoundedCornerShape(Radius.md)).background(p.accentDanger.copy(alpha = 0.12f))
                        .padding(horizontal = Space.s3, vertical = Space.s2),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                        Icon(SfIcon.vector("externaldrive.badge.exclamationmark"), null, tint = p.accentDanger, modifier = Modifier.size(16.dp))
                        Text("Couldn’t read this phone’s mail: $readError", color = p.textPrimary, style = AppFont.xs,
                            maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                        PillButton("Try again", compact = true, tint = Color.Transparent, contentColor = p.accentViolet) { refresh++ }
                    }
                }
                when (tab) {
                    LoreTab.TODAY -> {
                        if (query.isNotEmpty()) searchHits(query, openLore + archived, pages, cloud) { push(it) }
                        val loadError = state.loadError
                        if (!loaded) spinner() else if (next != null) {
                            item(key = "next") {
                                NextUpCard(next.lead, next.items, onOpen = onOpenConversation, onDone = { done(next.items) })
                            }
                        } else if (loadError != null) {
                            // The banner above says why; never "Nothing on your plate" over a failed read.
                        } else if (query.isNotEmpty() && handledCount == 0 && !hasEntityHits(query, openLore + archived, pages)) {
                            item { EmptyState("magnifyingglass", "No results", "Nothing in Lore matches “$query”.", modifier = Modifier.padding(top = Space.s6)) }
                        } else if (handledCount == 0 && todos.isEmpty()) {
                            item {
                                EmptyState("checkmark.circle", "Nothing on your plate",
                                    "New mail is sorted here as Jev triages it. Ask the mic to remind you of anything else.",
                                    modifier = Modifier.padding(top = Space.s8))
                            }
                        }
                        // The top "Do first" entry is the Next-up card, so the group starts after it.
                        group("Do first", p.accentViolet, today.firstGroups.filter { it.id != next?.id }, rowActions)
                        if (query.isEmpty() && loaded) orgsStrip(openLore, cloud) { push(it) }
                        today.sections.forEach { s -> group(s.title, bucketTint(p, s.bucket), s.groups.filter { it.id != next?.id }, rowActions) }
                        if (query.isEmpty()) todosGroup(todos, onComplete = ::complete, onAdd = { title ->
                            scope.launch { if (engine.addLoreTodo(title)) todos = engine.loreTodos() }
                        })
                        if (handledCount > 0) handledGroup(today.handled, expanded, ::toggle, rowActions, onItems = { l, act -> done(l, act) }) { g -> done(g.items, g.action) }
                        if (query.isEmpty()) pages?.let { (orgId, list) -> pagesGroup(orgId, list) { push(it) } }
                    }
                    LoreTab.WAITING -> if (!loaded) spinner() else {
                        val waiting = today.sections.first { it.bucket == LoreBucket.WAITING }.groups
                        group("Waiting on others", bucketTint(p, LoreBucket.WAITING), waiting, rowActions)
                        if (waiting.isEmpty() && readError == null) muted("Nothing waiting — no one owes you an answer.")
                    }
                    LoreTab.HANDLED ->
                        if (!loaded) spinner()
                        else if (handledCount > 0) handledGroup(today.handled, expanded, ::toggle, rowActions, onItems = { l, act -> done(l, act) }) { g -> done(g.items, g.action) }
                        else if (readError == null) muted("Nothing to review.")
                    LoreTab.HISTORY -> if (!historyLoaded) spinner() else historyGroup(archived.filter { LoreText.matches(it, query) }.take(100), onOpenConversation, ::putBack, quietWhenEmpty = readError != null)
                }
            }
        }
        // Undo for the last tick, where the inbox shows its own (same toast, same five seconds).
        state.undo?.let { u ->
            Box(Modifier.align(Alignment.TopCenter).padding(top = 120.dp)) {
                // undoRestore unmarks the rows and reverses the action; the re-read puts them back.
                UndoToast(u) { state.undoRestore(u); refresh++ }
            }
        }
        // The Bridge's voice orb, small and idling — tap to talk (voice is secondary now).
        Box(
            Modifier.align(Alignment.BottomEnd).padding(end = Space.s4, bottom = 92.dp).size(56.dp)
                .clip(CircleShape)
                .noRippleClickable(onClickLabel = "Talk to the Bridge") { onOpenBridge() }
                .semantics { contentDescription = "Talk to the Bridge" },
            contentAlignment = Alignment.Center,
        ) { Orb(active = false, size = 44.dp) }
    }
}

/** A compact pill whose tap target is ≥44dp tall: the capsule keeps its look, the
 *  clickable area around it grows. */
@Composable
private fun TallPill(label: String, tint: Color?, contentColor: Color? = null, onClick: () -> Unit) {
    Box(Modifier.heightIn(min = 44.dp).noRippleClickable(onClickLabel = label) { onClick() }, contentAlignment = Alignment.Center) {
        PillButton(label, compact = true, tint = tint, contentColor = contentColor, onClick = onClick)
    }
}

/** Until the first read finishes: never an empty-state message before then. */
private fun LazyListScope.spinner() {
    item(key = "loading") {
        Box(Modifier.fillMaxWidth().padding(top = Space.s8), contentAlignment = Alignment.Center) {
            androidx.compose.material3.CircularProgressIndicator(color = theme.accentViolet, modifier = Modifier.size(24.dp))
        }
    }
}

/** What a row can do — one bundle so the LazyListScope helpers stay readable. */
private class RowActions(
    val cloud: CloudSession,
    val onOpen: (Conversation) -> Unit,
    val onDone: (List<Conversation>) -> Unit,
    val onToggle: (String) -> Unit,
    val isOpen: (String) -> Boolean,
    val onEntity: (LoreEntityRef) -> Unit,
    val onSendTo: (Conversation) -> Unit,
    val sent: Map<String, LoreSentRef>,
)

private fun bucketTint(p: ThemePalette, b: LoreBucket): Color = when (b) {
    LoreBucket.PAY -> p.accentAmber
    LoreBucket.REPLY -> p.accentViolet
    LoreBucket.WORK -> p.accentPrimary
    LoreBucket.MEET -> p.accentTeal
    LoreBucket.REVIEW -> p.accentPurple
    LoreBucket.READ -> p.textTertiary
    LoreBucket.WAITING -> p.statusPending
    LoreBucket.HANDLED -> p.textMuted
}

private fun title(c: Conversation) = LoreText.clean(c.subject).ifEmpty { c.subject.ifEmpty { "(no subject)" } }

@Composable
private fun TabBar(tab: LoreTab, waiting: Int, handled: Int, query: String, onTab: (LoreTab) -> Unit, onQuery: (String) -> Unit) {
    val p = theme
    Column(Modifier.padding(bottom = Space.s3), verticalArrangement = Arrangement.spacedBy(Space.s2)) {
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = Space.s4),
            horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
            LoreTab.entries.forEach { v ->
                val on = v == tab
                val count = when (v) { LoreTab.WAITING -> waiting; LoreTab.HANDLED -> handled; else -> 0 }
                Row(Modifier.defaultMinSize(minHeight = 34.dp).clip(CircleShape)
                    .background(if (on) p.bgRaised else Color.Transparent)
                    .border(1.dp, if (on) p.borderDefault else p.borderSubtle, CircleShape)
                    .noRippleClickable(onClickLabel = v.title) { onTab(v) }
                    .semantics { contentDescription = if (on) "${v.title}, selected" else v.title }
                    .padding(horizontal = Space.s3),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(v.title, color = if (on) p.textPrimary else p.textSecondary, style = AppFont.sm.copy(fontWeight = FontWeight.SemiBold))
                    if (count > 0) Text("$count", color = p.textTertiary, style = AppFont.xs2)
                }
            }
        }
        Row(Modifier.padding(horizontal = Space.s4).fillMaxWidth().defaultMinSize(minHeight = 40.dp)
            .clip(RoundedCornerShape(Radius.md)).background(p.bgRaised).padding(horizontal = Space.s3),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
            Icon(SfIcon.vector("magnifyingglass"), null, tint = p.textTertiary, modifier = Modifier.size(16.dp))
            Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                if (query.isEmpty()) Text(if (tab == LoreTab.HISTORY) "Filter history" else "Search Lore — mail, people, pages",
                    color = p.textTertiary, style = AppFont.sm)
                BasicTextField(query, onQuery, singleLine = true,
                    textStyle = AppFont.sm.copy(color = p.textPrimary), cursorBrush = SolidColor(p.accentViolet),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), modifier = Modifier.fillMaxWidth())
            }
            if (query.isNotEmpty()) Icon(SfIcon.vector("xmark.circle.fill"), "Clear search", tint = p.textTertiary,
                modifier = Modifier.size(18.dp).noRippleClickable(onClickLabel = "Clear search") { onQuery("") })
        }
    }
}

@Composable
private fun NextUpCard(c: Conversation, items: List<Conversation>, onOpen: (Conversation) -> Unit, onDone: () -> Unit) {
    val p = theme
    val count = items.size
    var showAll by remember(c.id) { mutableStateOf(false) }
    val bucket = LoreBucket.forLabel(c.triageLabel) ?: LoreBucket.WORK
    val tint = bucketTint(p, bucket)
    val tagText = if (TriageLabel.from(c.triageLabel) == null)
        TriageLabelNames.name(c.triageLabel.orEmpty(), c.accountKey, AccountKey.isDomain(c.accountKey)) else bucket.tag
    Column(
        Modifier.padding(horizontal = Space.s4).padding(bottom = Space.s4).fillMaxWidth()
            .clip(RoundedCornerShape(Radius.xl)).background(p.bgPanel)
            .border(1.dp, p.borderSubtle, RoundedCornerShape(Radius.xl))
            .padding(Space.s4),
        verticalArrangement = Arrangement.spacedBy(Space.s2),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
            Text("NEXT UP", color = p.ringColors.getOrElse(1) { p.accentViolet }, style = AppFont.xs3.copy(fontWeight = FontWeight.Bold))
            Text(tagText, color = tint, style = AppFont.xs3,
                modifier = Modifier.clip(CircleShape).background(tint.copy(alpha = 0.14f)).padding(horizontal = Space.s2, vertical = 2.dp))
            Spacer(Modifier.weight(1f))
            Text(c.time, color = p.textTertiary, style = AppFont.xs2)
        }
        Text(title(c), color = p.textPrimary, style = AppFont.lg, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Text(c.preview, color = p.textSecondary, style = AppFont.sm, maxLines = 3, overflow = TextOverflow.Ellipsis)
        Text(c.sender, color = p.textTertiary, style = AppFont.xs2)
        // The other emails in this group, to inspect before "Done (N)" archives them all.
        if (count > 1) {
            Row(Modifier.heightIn(min = 44.dp)
                .noRippleClickable(onClickLabel = if (showAll) "Hide the emails" else "Show the $count emails") { showAll = !showAll },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s1)) {
                Icon(SfIcon.vector("chevron.right"), null, tint = p.textSecondary, modifier = Modifier.size(10.dp).rotate(if (showAll) 90f else 0f))
                Text("$count emails", color = p.textSecondary, style = AppFont.xs.copy(fontWeight = FontWeight.SemiBold))
            }
            if (showAll) items.drop(1).forEach { o ->
                Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).noRippleClickable(onClickLabel = "Open the email") { onOpen(o) },
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                    Icon(SfIcon.vector("envelope"), null, tint = p.textTertiary, modifier = Modifier.size(14.dp))
                    Text(title(o), color = p.textPrimary, style = AppFont.sm, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    Text(o.time, color = p.textTertiary, style = AppFont.xs2)
                }
            }
        }
        Row(Modifier.padding(top = Space.s1), horizontalArrangement = Arrangement.spacedBy(Space.s3)) {
            PillButton(if (bucket == LoreBucket.REPLY) "Open & reply" else "Open email",
                modifier = Modifier.weight(1f).defaultMinSize(minHeight = 44.dp),
                icon = if (bucket == LoreBucket.REPLY) "arrowshape.turn.up.left" else "envelope.open", onClick = { onOpen(c) })
            PillButton(if (count > 1) "Done ($count)" else "Done", compact = true, tint = p.bgRaised, contentColor = p.textPrimary, icon = "checkmark",
                modifier = Modifier.defaultMinSize(minWidth = 96.dp, minHeight = 44.dp), onClick = onDone)
        }
    }
}

private fun LazyListScope.groupHeader(title: String, tint: Color?, count: Int, key: String = title) {
    item(key = "h:$key") {
        val p = theme
        Row(Modifier.fillMaxWidth().padding(horizontal = Space.s4).padding(top = Space.s4, bottom = Space.s1),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(tint ?: p.accentTeal))
            Text(title, color = p.textSecondary, style = AppFont.label(13))
            Text("$count", color = p.textTertiary, style = AppFont.xs2)
        }
    }
}

private fun LazyListScope.muted(text: String) {
    item { Text(text, color = theme.textTertiary, style = AppFont.sm, modifier = Modifier.padding(horizontal = Space.s4, vertical = Space.s2)) }
}

private fun LazyListScope.group(title: String, tint: Color, groups: List<LoreGroup>, a: RowActions) {
    if (groups.isEmpty()) return
    groupHeader(title, tint, groups.sumOf { it.items.size })
    groups.forEach { g ->
        item(key = "c:${g.id}") { SwipeDone(onDone = { a.onDone(g.items) }) { LoreRow(g.lead, tint, g, a) } }
        // The lead is already the row above: unfold only the others.
        if (g.items.size > 1 && a.isOpen(g.id)) items(g.items.drop(1), key = { "c:${g.id}:${it.id}" }) { c ->
            SwipeDone(onDone = { a.onDone(listOf(c)) }) { LoreRow(c, null, null, a, indent = true) }
        }
    }
}

/** A to-do row: the section's colour in the gutter (fading as the mail ages — web
 *  `ageStep`), the checkbox, then title/summary/sender. `group` (2+ threads) makes
 *  it stand for all of them, with an "N emails" chip that unfolds the list.
 *  Long-press: the sender's Lore pages (the desktop's @mentions). */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun LoreRow(c: Conversation, tint: Color?, group: LoreGroup?, a: RowActions, indent: Boolean = false) {
    val p = theme
    val many = (group?.items?.size ?: 0) > 1
    var menu by remember { mutableStateOf(false) }
    val fade = floatArrayOf(1f, 0.75f, 0.5f, 0.35f, 0.2f)[LoreText.ageStep(c)]
    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).background(p.bgBase)
        .padding(start = if (indent) Space.s6 else Space.s1, end = Space.s4),
        verticalAlignment = Alignment.Top) {
        Box(Modifier.padding(vertical = Space.s2).width(3.dp).fillMaxHeight().clip(RoundedCornerShape(2.dp))
            .background((tint ?: Color.Transparent).copy(alpha = if (tint == null) 0f else fade)))
        Checkbox(c.subject) { a.onDone(group?.items ?: listOf(c)) }
        Column(Modifier.weight(1f)) {
            Column(Modifier.fillMaxWidth()
                .combinedClickable(interactionSource = remember { MutableInteractionSource() }, indication = null,
                    onClickLabel = "Open the email", onLongClickLabel = "Open the sender's Lore page",
                    onLongClick = { menu = true }) { a.onOpen(c) }
                .padding(vertical = Space.s2),
                verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                    Text(title(c), color = p.textPrimary,
                        style = if (c.unread) AppFont.base.copy(fontWeight = FontWeight.SemiBold) else AppFont.base,
                        maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    Spacer(Modifier.weight(1f))
                    Text(c.time, color = p.textTertiary, style = AppFont.xs2)
                }
                Text(c.preview, color = p.textSecondary, style = AppFont.xs, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s1)) {
                    LoreText.orgDomain(c.email)?.let { LoreLogo(it, a.cloud, 14.dp) }
                        // A personal-address sender (gmail.com…) is a person: their initials.
                        ?: AvatarRing(MailAddress.initials(c.fromAddress), size = 14.dp, seed = MailAddress.seed(c.email))
                    Text(c.sender, color = p.textTertiary, style = AppFont.xs2, maxLines = 1)
                    a.sent[LoreSentRef.key(c)]?.let { SentChip(it) }
                }
            }
            // A sibling below the open-email target, never inside it: unfolding can't open the lead.
            if (many && group != null) {
                val open = a.isOpen(group.id)
                Row(Modifier.padding(bottom = Space.s2).clip(CircleShape).background(p.bgRaised)
                    .noRippleClickable(onClickLabel = if (open) "Hide the emails" else "Show the ${group.items.size} emails") { a.onToggle(group.id) }
                    .padding(horizontal = Space.s2, vertical = 3.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                    Icon(SfIcon.vector("chevron.right"), null, tint = p.textSecondary,
                        modifier = Modifier.size(9.dp).rotate(if (open) 90f else 0f))
                    Text("${group.items.size} emails", color = p.textSecondary, style = AppFont.xs3.copy(fontWeight = FontWeight.SemiBold))
                }
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text("Send to…") }, onClick = { menu = false; a.onSendTo(c) })
                LoreText.orgDomain(c.email)?.let { d ->
                    DropdownMenuItem(text = { Text("Open ${LoreText.domainLabel(d)}") },
                        onClick = { menu = false; a.onEntity(LoreEntityRef.Org(d)) })
                }
                if (c.email.isNotEmpty()) DropdownMenuItem(text = { Text("Open ${c.sender}") },
                    onClick = { menu = false; a.onEntity(LoreEntityRef.Person(c.email.lowercase(), c.sender)) })
            }
        }
    }
}

/** The chip Send to… left on the row. The link opens only from this tap. */
@Composable
private fun SentChip(ref: LoreSentRef) {
    val p = theme
    val uri = androidx.compose.ui.platform.LocalUriHandler.current
    val link = ref.url?.takeIf { it.startsWith("https://") || it.startsWith("http://") }
    Text(ref.chipLabel, color = p.textSecondary, style = AppFont.xs3.copy(fontWeight = FontWeight.SemiBold),
        modifier = Modifier.clip(CircleShape).background(p.bgRaised)
            .then(if (link != null) Modifier.noRippleClickable(onClickLabel = "Open in the other app") { uri.openUri(link) } else Modifier)
            .padding(horizontal = Space.s2, vertical = 2.dp))
}

/** Swipe left = done (the inbox's full-swipe archive, on Lore). */
@Composable
private fun SwipeDone(onDone: () -> Unit, content: @Composable () -> Unit) {
    val p = theme
    val swipe = rememberSwipeToDismissBoxState()
    SwipeToDismissBox(
        state = swipe,
        enableDismissFromStartToEnd = false,
        onDismiss = { if (it == SwipeToDismissBoxValue.EndToStart) onDone() },
        backgroundContent = {
            Box(Modifier.fillMaxSize().background(p.accentSuccess.copy(alpha = 0.18f)).padding(horizontal = Space.s5),
                contentAlignment = Alignment.CenterEnd) {
                Icon(SfIcon.vector("checkmark"), "Done", tint = p.accentSuccess, modifier = Modifier.size(22.dp))
            }
        },
    ) { content() }
}

/** A real ≥44dp checkbox: a 22dp ring, the whole 44dp square is the target. */
@Composable
private fun Checkbox(label: String, onCheck: () -> Unit) {
    val p = theme
    Box(Modifier.size(44.dp).noRippleClickable(onClickLabel = "Mark done") { onCheck() }
        .semantics { contentDescription = "Mark done: $label" },
        contentAlignment = Alignment.Center) {
        Box(Modifier.size(22.dp).border(1.5.dp, p.borderStrong, CircleShape))
    }
}

private fun LazyListScope.todosGroup(todos: List<LoreTodo>, onComplete: (LoreTodo) -> Unit, onAdd: (String) -> Unit) {
    groupHeader("My todos", null, todos.size)
    items(todos, key = { "t:${it.id}" }) { t ->
        SwipeDone(onDone = { onComplete(t) }) {
            val p = theme
            Row(Modifier.fillMaxWidth().background(p.bgBase).padding(start = Space.s1, end = Space.s4),
                verticalAlignment = Alignment.CenterVertically) {
                Checkbox(t.title) { onComplete(t) }
                Text(t.title, color = p.textPrimary, style = AppFont.base, modifier = Modifier.weight(1f))
                if (t.source == "voice") Icon(SfIcon.vector("mic.fill"), "Added by voice", tint = p.textTertiary, modifier = Modifier.size(14.dp))
            }
        }
    }
    item(key = "add") {
        val p = theme
        var text by remember { mutableStateOf("") }
        fun submit() { text.trim().takeIf { it.isNotEmpty() }?.let(onAdd); text = "" }
        Row(Modifier.fillMaxWidth().padding(start = Space.s1, end = Space.s4), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) {
                Icon(SfIcon.vector("plus"), null, tint = p.textTertiary, modifier = Modifier.size(18.dp))
            }
            Box(Modifier.weight(1f).defaultMinSize(minHeight = 44.dp), contentAlignment = Alignment.CenterStart) {
                if (text.isEmpty()) Text("Add todo", color = p.textTertiary, style = AppFont.base)
                BasicTextField(text, { text = it }, singleLine = true,
                    textStyle = AppFont.base.copy(color = p.textPrimary), cursorBrush = SolidColor(p.accentViolet),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { submit() }),
                    modifier = Modifier.fillMaxWidth())
            }
        }
    }
}

/** "Handled for you": each group taps open to show its threads (open one, or swipe it
 *  alone) before its button acts on all of them. */
private fun LazyListScope.handledGroup(
    groups: List<LoreHandledGroup>, expanded: Set<String>, onToggle: (String) -> Unit, a: RowActions,
    onItems: (List<Conversation>, ConversationAction) -> Unit, onAct: (LoreHandledGroup) -> Unit,
) {
    item(key = "h:handled") {
        val p = theme
        Row(Modifier.fillMaxWidth().padding(horizontal = Space.s4).padding(top = Space.s4, bottom = Space.s1),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(p.textMuted))
            Text("Handled for you — waiting for your OK", color = p.textSecondary, style = AppFont.label(13))
        }
    }
    groups.filter { it.items.isNotEmpty() }.forEach { g ->
        val key = "handled:${g.label.raw}"
        val open = key in expanded
        item(key = "g:${g.label.raw}") {
            val p = theme
            Row(Modifier.fillMaxWidth().padding(horizontal = Space.s4, vertical = Space.s1),
                verticalAlignment = Alignment.CenterVertically) {
                Row(Modifier.weight(1f).defaultMinSize(minHeight = 44.dp)
                    .noRippleClickable(onClickLabel = if (open) "Hide the ${g.title}" else "Show the ${g.items.size} ${g.title}") { onToggle(key) },
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                    Icon(SfIcon.vector("chevron.right"), null, tint = p.textSecondary, modifier = Modifier.size(10.dp).rotate(if (open) 90f else 0f))
                    Text("${g.items.size} ${g.title.lowercase()}", color = p.textSecondary, style = AppFont.sm)
                }
                Spacer(Modifier.width(Space.s3))
                TallPill("${g.buttonLabel} ${g.items.size}", tint = if (g.action == ConversationAction.Trash) p.accentDanger else null) { onAct(g) }
            }
        }
        if (open) items(g.items, key = { "hc:${it.id}" }) { c ->
            // Tick or swipe runs the group's own action (Delete for sign-in codes), not archive.
            val ga = RowActions(a.cloud, a.onOpen, { onItems(it, g.action) }, a.onToggle, a.isOpen, a.onEntity, a.onSendTo, a.sent)
            SwipeDone(onDone = { ga.onDone(listOf(c)) }) { LoreRow(c, null, null, ga) }
        }
    }
    item { Spacer(Modifier.height(Space.s2)) }
}

/** Organizations behind the open work, most threads first (the desktop sidebar's list). */
private fun orgCounts(open: List<Conversation>): List<Pair<String, Int>> =
    open.mapNotNull { LoreText.orgDomain(it.email) }.groupingBy { it }.eachCount()
        .toList().sortedWith(compareByDescending<Pair<String, Int>> { it.second }.thenBy { it.first })

private fun LazyListScope.orgsStrip(open: List<Conversation>, cloud: CloudSession, onEntity: (LoreRoute) -> Unit) {
    val orgs = orgCounts(open)
    if (orgs.isEmpty()) return
    groupHeader("Organizations", null, orgs.size)
    item(key = "orgs") {
        val p = theme
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = Space.s4),
            horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
            orgs.take(12).forEach { (domain, count) ->
                Row(Modifier.defaultMinSize(minHeight = 40.dp).clip(CircleShape).background(p.bgRaised)
                    .noRippleClickable(onClickLabel = "Open ${LoreText.domainLabel(domain)}") { onEntity(LoreRoute.Entity(LoreEntityRef.Org(domain))) }
                    .padding(horizontal = Space.s3),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                    LoreLogo(domain, cloud, 22.dp)
                    Text(LoreText.domainLabel(domain), color = p.textPrimary, style = AppFont.sm)
                    Text("$count", color = p.textTertiary, style = AppFont.xs2)
                }
            }
        }
    }
}

private fun LazyListScope.pagesGroup(orgId: String, list: List<LorePageRef>, keyPrefix: String = "p", onPage: (LoreRoute) -> Unit) {
    if (list.isEmpty()) return
    groupHeader("Pages", null, list.size, key = "$keyPrefix:pages")
    items(list, key = { "$keyPrefix:${it.id}" }) { page ->
        val p = theme
        Row(Modifier.fillMaxWidth().defaultMinSize(minHeight = 44.dp)
            .noRippleClickable(onClickLabel = "Open ${page.name}") { onPage(LoreRoute.Page(orgId, page)) }
            .padding(horizontal = Space.s4),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s3)) {
            Icon(SfIcon.vector("doc.text"), null, tint = p.textTertiary, modifier = Modifier.size(16.dp))
            Text(page.name, color = p.textPrimary, style = AppFont.base)
        }
    }
}

/** Does the search name an organization, person or page? Then "No results" would be wrong. */
private fun hasEntityHits(query: String, rows: List<Conversation>, pages: Pair<String, List<LorePageRef>>?): Boolean {
    val q = query.trim()
    return orgCounts(rows).any { it.first.contains(q, ignoreCase = true) } ||
        loreSenders(rows).any { it.name.contains(q, ignoreCase = true) || it.address.contains(q, ignoreCase = true) } ||
        pages?.second.orEmpty().any { it.name.contains(q, ignoreCase = true) }
}

/** Search's non-mail hits: organizations, people and pages whose name matches. */
private fun LazyListScope.searchHits(
    query: String, rows: List<Conversation>, pages: Pair<String, List<LorePageRef>>?, cloud: CloudSession, onRoute: (LoreRoute) -> Unit,
) {
    val q = query.trim()
    val orgHits = orgCounts(rows).filter { it.first.contains(q, ignoreCase = true) }.take(8)
    val people = loreSenders(rows).filter { it.name.contains(q, ignoreCase = true) || it.address.contains(q, ignoreCase = true) }.take(8)
    if (orgHits.isNotEmpty() || people.isNotEmpty()) {
        groupHeader("Organizations & people", null, orgHits.size + people.size)
        items(orgHits, key = { "so:${it.first}" }) { (d, _) ->
            EntityLink(LoreText.domainLabel(d), d, "building.2", logo = { LoreLogo(d, cloud, 20.dp) }) { onRoute(LoreRoute.Entity(LoreEntityRef.Org(d))) }
        }
        items(people, key = { "sp:${it.address}" }) { s ->
            EntityLink(s.name, s.address, "person") { onRoute(LoreRoute.Entity(LoreEntityRef.Person(s.address, s.name))) }
        }
    }
    pages?.let { (orgId, list) -> pagesGroup(orgId, list.filter { it.name.contains(q, ignoreCase = true) }, keyPrefix = "sp", onPage = onRoute) }
}

@Composable
private fun EntityLink(title: String, detail: String, icon: String, logo: (@Composable () -> Unit)? = null, onClick: () -> Unit) {
    val p = theme
    Row(Modifier.fillMaxWidth().defaultMinSize(minHeight = 44.dp).noRippleClickable(onClickLabel = "Open $title") { onClick() }
        .padding(horizontal = Space.s4),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s3)) {
        if (logo != null) logo() else Icon(SfIcon.vector(icon), null, tint = p.textTertiary, modifier = Modifier.size(16.dp))
        Text(title, color = p.textPrimary, style = AppFont.base)
        Text(detail, color = p.textTertiary, style = AppFont.xs2, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** Recently archived Lore threads; "Put back" returns one to the inbox and Today. */
private fun LazyListScope.historyGroup(rows: List<Conversation>, onOpen: (Conversation) -> Unit, onPutBack: (Conversation) -> Unit, quietWhenEmpty: Boolean = false) {
    groupHeader("History", null, rows.size)
    if (rows.isEmpty() && !quietWhenEmpty) muted("Nothing here yet.")
    items(rows, key = { "hist:${it.id}" }) { c ->
        val p = theme
        Row(Modifier.fillMaxWidth().padding(horizontal = Space.s4), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
            Row(Modifier.weight(1f).defaultMinSize(minHeight = 44.dp).noRippleClickable(onClickLabel = "Open the email") { onOpen(c) },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                Icon(SfIcon.vector("checkmark.circle.fill"), null, tint = p.accentSuccess, modifier = Modifier.size(16.dp))
                Column {
                    Text(title(c), color = p.textPrimary, style = AppFont.base, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("${c.sender} · ${c.time}", color = p.textTertiary, style = AppFont.xs2, maxLines = 1)
                }
            }
            TallPill("Put back", tint = Color.Transparent, contentColor = p.accentViolet) { onPutBack(c) }
        }
    }
}

/** Distinct senders, most threads first (web `entitiesFrom().people`). */
internal data class LoreSender(val address: String, val name: String, val count: Int)

internal fun loreSenders(rows: List<Conversation>): List<LoreSender> =
    rows.filter { it.email.isNotEmpty() }.groupBy { it.email.lowercase() }
        .map { (addr, list) -> LoreSender(addr, list.first().sender, list.size) }
        .sortedWith(compareByDescending<LoreSender> { it.count }.thenBy { it.name })
