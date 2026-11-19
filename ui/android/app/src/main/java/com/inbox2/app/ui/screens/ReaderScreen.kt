package com.inbox2.app.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.model.AccountKey
import com.inbox2.app.model.Conversation
import com.inbox2.app.model.ConversationAction
import com.inbox2.app.model.MailFolder
import com.inbox2.app.model.Message
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.ProcessingHairline
import com.inbox2.app.ui.components.*
import uniffi.inbox2_core.FfiBridgeConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Threaded reader (iOS MessageView): collapsible AI summary, a stack of per-message
 *  cards (newest expanded), each rendering the body via MessageBodyWebView, with a
 *  bottom actions bar (reply/reply-all/forward + archive/trash). */
@Composable
fun ReaderScreen(
    engine: EngineModel,
    cloud: com.inbox2.app.cloud.CloudSession,
    convo: Conversation,
    onBack: () -> Unit,
    onReply: (ComposePrefill) -> Unit,
    onSearchSender: (String) -> Unit = {},
    /** The folder this thread was opened from — hides destructive actions that are
     *  redundant there (Archive in Archive/Trash/Sent, Trash in Trash). */
    folder: MailFolder = MailFolder.INBOX,
    /** Every action applied here is reported to the shell, which owns the list-side
     *  effects (notification clear, row suppression, undo toast) and closes the reader
     *  on a destructive one. Defaults to popping (no list context). */
    onAdvance: (Conversation, ConversationAction) -> Unit = { _, a -> if (a.removesRow) onBack() },
    /** A domain thread was snoozed here: the shell drops the row + closes the reader
     *  (iOS: "the list owns dropping the row"). */
    onSnoozed: (Conversation) -> Unit = { onBack() },
    /** A tapped body link → the shell's in-app browser. */
    onOpenUrl: (String) -> Unit = {},
    /** An invite banner tap / "View" → the calendar, straight to that event's detail. */
    onOpenEvent: (String) -> Unit = {},
) {
    val p = theme
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()
    var messages by remember { mutableStateOf<List<Message>>(emptyList()) }
    var summaryOpen by remember { mutableStateOf(false) }   // collapsed by default (iOS)
    var domain by remember { mutableStateOf<com.inbox2.app.cloud.DomainThread?>(null) }
    val cloudRevision by cloud.revision.collectAsState()
    // On open, a multi-message thread lands on the last (expanded) message's header
    // rather than the top of a long thread (iOS MessageView parity).
    val listState = androidx.compose.foundation.lazy.rememberLazyListState()
    var didInitialScroll by remember(convo.id) { mutableStateOf(false) }

    var sealedLocked by remember(convo.id) { mutableStateOf(false) }

    LaunchedEffect(convo.id, cloudRevision) {
        if (convo.isDomain) {
            val t = runCatching { cloud.thread(convo.accountKey, convo.id) }.getOrNull()
            domain = t
            messages = t?.messages ?: emptyList()
            sealedLocked = t?.sealedLocked == true
        } else {
            messages = withContext(Dispatchers.IO) { engine.store.messages(convo.id) }
        }
    }
    // Once messages land, jump a real thread to its last (expanded) message so its
    // header sits at the top. Single-message threads start at the top anyway (and
    // scrolling would push the AI summary off-screen), so only for count > 1.
    LaunchedEffect(messages) {
        if (!didInitialScroll && messages.size > 1) {
            didInitialScroll = true
            val headerItems = (if (convo.aiSummary?.isNotBlank() == true) 1 else 0) +
                (if (domain != null) 1 else 0)
            listState.scrollToItem((headerItems + messages.lastIndex).coerceAtLeast(0))
        }
    }
    suspend fun act(verb: String) = engine.performRouted(cloud, convo.accountKey, listOf(convo.id), verb)
    // Answering an invite archives the thread from the inbox (web/desktop/iOS do the
    // same); in archive/sent/trash/spam it stays where it is (the ••• menu's Archive rule).
    val archivesOnRsvp = !folder.hidesArchiveAction && folderRestoreAction(folder) == null &&
        convo.status != com.inbox2.app.model.ConvStatusValue.ARCHIVED
    // The channel account's own address — reply-all strips it (domain threads resolve theirs in replyPrefill).
    val accountEmail = engine.accounts.value.firstOrNull { it.id == convo.accountKey }?.email

    // Mark-as-read honoring the user's mode (iOS MarkReadManager) — the policy
    // machine (immediate / dwell / on-leave / never + notification clear) lives in
    // rememberMarkRead so any reading surface can reuse it.
    rememberMarkRead(convo.id, convo.unread) { act(ConversationAction.MarkRead.verb) }

    // Stale-summary cue: the stored AI summaries were generated for an older
    // message than the one on screen and the triage worker is running — show the
    // hairline below the header until they land (iOS MessageView parity).
    val triage by engine.triage.collectAsState()
    val dataVersion by engine.dataVersion.collectAsState()
    var summariesProcessing by remember(convo.id) { mutableStateOf(false) }
    LaunchedEffect(convo.id, dataVersion, triage.pending) {
        val stored = if (convo.isDomain) null
        else withContext(Dispatchers.IO) { engine.store.conversation(convo.id) }
        // Only light the hairline when the worker is actually AT this thread — not
        // when it's merely queued behind a long backlog. The queue drains newest-first
        // and currentDate is the head job's date (== a conversation updated_at); a
        // pending thread is always at-or-older than the head, so it's the head exactly
        // when its date catches up. Mid-backlog threads stay dark instead of nagging.
        val stale = triage.isActive && !(stored?.summariesCurrent ?: true)
        val atWorkerHead = run {
            val head = com.inbox2.app.model.RelativeTime.parse(triage.currentDate ?: "") ?: return@run false
            val mine = com.inbox2.app.model.RelativeTime.parse(stored?.updatedAt ?: convo.updatedAt) ?: return@run false
            mine.time >= head.time - 1000   // within 1s → this thread is the current head
        }
        summariesProcessing = stale && atWorkerHead
    }

    // Read-aloud + voice triage (iOS ReadAloudController): the header speaker
    // button reads the stored summary, then opens a 5 s hands-free filing window.
    val voicePrefs = remember { com.inbox2.app.engine.VoicePrefs(ctx) }
    val speaker = remember { com.inbox2.app.audio.Speaker(ctx, engine, voicePrefs) }
    val readAloud = remember {
        com.inbox2.app.audio.ReadAloudController(
            engine, voicePrefs, speaker, com.inbox2.app.audio.TriageListener(ctx), scope,
        )
    }
    val readPhase by readAloud.phase.collectAsState()
    DisposableEffect(Unit) { onDispose { readAloud.stop(); speaker.shutdown() } }

    var overflow by remember { mutableStateOf(false) }
    var reprocessing by remember { mutableStateOf(false) }

    // "Speak with" summary tiers + "Process with" engines (iOS speakWithMenu /
    // MessageProcessMenu). The engines offered are whatever's ready right now: each
    // installed free variant (Qwen/Gemma) and OpenAI when a key is saved.
    val speakWith = run {
        val onDevice = { id: String ->
            FfiBridgeConfig(generation = "apple", openaiKey = null, model = null, onDeviceModel = id, concise = false, weather = null)
        }
        val opts = buildList {
            if (engine.modelPath(com.inbox2.app.engine.BridgeModelIds.QWEN) != null)
                add(ProcessOption(com.inbox2.app.engine.BridgeModelIds.QWEN, "Qwen", "cpu", onDevice(com.inbox2.app.engine.BridgeModelIds.QWEN)))
            if (engine.modelPath(com.inbox2.app.engine.BridgeModelIds.GEMMA) != null)
                add(ProcessOption(com.inbox2.app.engine.BridgeModelIds.GEMMA, "Gemma", "cpu", onDevice(com.inbox2.app.engine.BridgeModelIds.GEMMA)))
            if (voicePrefs.hasKey)
                add(ProcessOption("openai", "OpenAI", "cloud",
                    FfiBridgeConfig(generation = "openai", openaiKey = voicePrefs.openAIKey, model = null, onDeviceModel = null, concise = false, weather = null)))
        }
        SpeakWith(
            short = convo.aiSummaryShort, medium = convo.aiSummaryMedium, large = convo.aiSummary,
            onSpeak = { readAloud.speakPlain(it) },
            onSpeakFull = {
                val m = messages.lastOrNull()
                val raw = m?.bodyPlain?.takeIf { it.isNotEmpty() } ?: m?.bodyHTML ?: ""
                readAloud.speakPlain(stripHtmlToText(raw).ifBlank { convo.snippet })
            },
            processOptions = opts,
            onProcess = { opt ->
                if (!reprocessing) {
                    reprocessing = true
                    scope.launch { engine.reprocessConversation(opt.config, convo.id); reprocessing = false }
                }
            },
        )
    }
    Box(Modifier.fillMaxSize().background(p.bgBase)) {
        Column(Modifier.fillMaxSize()) {
            ScreenHeader(title = convo.subject.ifEmpty { "(No subject)" }, showBack = true, onBack = onBack, uppercase = false) {
                Icon(
                    SfIcon.vector("speaker.wave.2"), "Read aloud",
                    tint = if (readPhase != com.inbox2.app.audio.ReadAloudController.Phase.IDLE) p.accentViolet else p.textSecondary,
                    modifier = Modifier.size(22.dp).noRippleClickable {
                        if (readPhase != com.inbox2.app.audio.ReadAloudController.Phase.IDLE) readAloud.stop()
                        else readAloud.start(convo) { action ->
                            scope.launch { act(action.verb) }
                            onAdvance(convo, action)
                        }
                    },
                )
                Box {
                    Icon(SfIcon.vector("ellipsis"), "More", tint = p.textSecondary,
                        modifier = Modifier.size(22.dp).noRippleClickable { overflow = true })
                    ConvActionMenu(
                        expanded = overflow, onDismiss = { overflow = false }, convo = convo,
                        folder = folder,
                        onReply = { onReply(replyPrefill(convo, messages.lastOrNull(), all = false, domainEmails(convo, cloud), accountEmail)) },
                        onReplyAll = { onReply(replyPrefill(convo, messages.lastOrNull(), all = true, domainEmails(convo, cloud), accountEmail)) },
                        onForward = { scope.launch { onReply(forwardPrefill(engine, convo, messages.lastOrNull(), domainEmails(convo, cloud))) } },
                        onSnooze = if (convo.isDomain) { { w ->
                            scope.launch { cloud.snooze(convo.accountKey, convo.id, java.time.Instant.ofEpochMilli(w.date().time).toString()) }
                            onSnoozed(convo)
                        } } else null,
                        speak = speakWith,
                        onAction = { action ->
                            scope.launch { act(action.verb) }
                            onAdvance(convo, action)
                        },
                    )
                }
            }
            if (summariesProcessing || reprocessing) ProcessingHairline()
            if (readPhase == com.inbox2.app.audio.ReadAloudController.Phase.LISTENING) {
                Text(
                    "Listening. Trash or archive?", color = p.accentViolet, style = AppFont.xs,
                    modifier = Modifier
                        .align(androidx.compose.ui.Alignment.CenterHorizontally)
                        .padding(vertical = Space.s1),
                )
            }

            // Pinned above the list: the reader scrolls to the last message.
            if (sealedLocked) SealedBanner(cloud, convo.accountKey, convo.id)
            LazyColumn(
                Modifier.weight(1f),
                state = listState,
                contentPadding = PaddingValues(vertical = Space.s2),
                verticalArrangement = Arrangement.spacedBy(Space.s3),
            ) {
                // AI summary panel
                convo.aiSummary?.takeIf { it.isNotBlank() }?.let { summary ->
                    item {
                        Column(Modifier.insetCard().padding(Space.s4)) {
                            Row(
                                Modifier.fillMaxWidth().noRippleClickable { summaryOpen = !summaryOpen },
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Icon(SfIcon.vector("sparkles"), null, tint = p.accentViolet, modifier = Modifier.size(14.dp))
                                Spacer(Modifier.width(Space.s2))
                                InboxTag("AI summary", p.accentViolet)
                                Spacer(Modifier.weight(1f))
                                // Sentiment/intent live here, not on the message header
                                // (iOS AISummaryPanel; duplicates were dropped there).
                                messages.lastOrNull()?.let { m ->
                                    m.sentimentPositive?.let { SentimentBadge(it); Spacer(Modifier.width(Space.s2)) }
                                    m.intentKind?.let { IntentBadge(it); Spacer(Modifier.width(Space.s2)) }
                                }
                                Icon(
                                    SfIcon.vector(if (summaryOpen) "chevron.down" else "chevron.right"),
                                    null, tint = p.textTertiary, modifier = Modifier.size(16.dp),
                                )
                            }
                            AnimatedVisibility(summaryOpen) {
                                Column(Modifier.padding(top = Space.s2)) {
                                    // Split into bullets on newline/• like iOS AISummaryPanel.
                                    val bullets = summary.split("\n", "•").map { it.trim() }.filter { it.isNotEmpty() }
                                    if (bullets.size > 1) bullets.forEach { line ->
                                        Row(Modifier.padding(vertical = 1.dp)) {
                                            Text("•  ", color = p.statusAI, style = AppFont.sm)
                                            Text(line, color = p.textSecondary, style = AppFont.sm)
                                        }
                                    } else Text(summary, color = p.textSecondary, style = AppFont.sm)
                                }
                            }
                        }
                    }
                }

                // Domain (mx) collaboration: tags, assignees, notes.
                domain?.let { d ->
                    item { DomainCollab(cloud, convo, d) }
                }

                itemsIndexed(messages, key = { _, m -> m.id }) { index, msg ->
                    MessageCard(engine, cloud, convo, msg, expandedInitially = index == messages.lastIndex,
                        onCompose = onReply, onSearchSender = onSearchSender, onOpenUrl = onOpenUrl, onOpenEvent = onOpenEvent,
                        onInviteAnswered = if (archivesOnRsvp) { {
                            scope.launch { act(ConversationAction.Archive.verb) }
                            onAdvance(convo, ConversationAction.Archive)
                        } } else null)
                }
                item { Spacer(Modifier.height(40.dp)) }
            }
            // iOS reader has no persistent bottom action bar — reply/forward/archive/trash
            // all live in the ••• menu (see ConvActionMenu above).
        }
    }
}

@Composable
private fun ActionPill(icon: String, label: String, onClick: () -> Unit) {
    val p = theme
    Row(
        Modifier.clip(RoundedCornerShape(Radius.full)).background(p.bgElevated)
            .noRippleClickable { onClick() }
            .padding(horizontal = Space.s3, vertical = Space.s2),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(SfIcon.vector(icon), label, tint = p.accentViolet, modifier = Modifier.size(16.dp))
        Text(label, color = p.textSecondary, style = AppFont.xs)
    }
}

@Composable
private fun IconAction(icon: String, onClick: () -> Unit) =
    AeroIconButton(icon, onClick, boxSize = 40.dp, iconSize = 18.dp, background = theme.bgElevated)
