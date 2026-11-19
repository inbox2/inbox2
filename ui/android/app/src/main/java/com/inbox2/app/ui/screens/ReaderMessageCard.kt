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

// One message card of the reader thread (split out of ReaderScreen.kt, 2026-10-18;
// names kept so logcat/greps stay valid): the card itself + its address/date/detail
// rows and the attachment glyph picker.
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
internal fun MessageCard(
    engine: EngineModel, cloud: com.inbox2.app.cloud.CloudSession,
    convo: Conversation, msg: Message, expandedInitially: Boolean,
    onCompose: (ComposePrefill) -> Unit, onSearchSender: (String) -> Unit,
    onOpenUrl: (String) -> Unit = {}, onOpenEvent: (String) -> Unit = {},
    /** An RSVP on this card's invite landed: the reader archives the thread (answering an
     *  invite is done with the mail, as on web/desktop/iOS). Null where it stays put. */
    onInviteAnswered: (() -> Unit)? = null,
) {
    val p = theme
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()
    // "Save to Files…" — download bytes (cached), stash, then write to the SAF uri.
    var pendingSave by remember { mutableStateOf<ByteArray?>(null) }
    val saveLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("*/*")) { uri ->
        val data = pendingSave
        if (uri != null && data != null) {
            scope.launch(Dispatchers.IO) { runCatching { ctx.contentResolver.openOutputStream(uri)?.use { it.write(data) } } }
        }
        pendingSave = null
    }
    var expanded by remember { mutableStateOf(expandedInitially) }
    var blocked by remember { mutableIntStateOf(0) }
    var showImages by remember { mutableStateOf(false) }
    // Proxied image fetches the upstream host refused (bot-managed CDNs), and the
    // explicit per-message consent to load just those images directly.
    var proxyFailed by remember { mutableIntStateOf(0) }
    var loadFailedDirect by remember { mutableStateOf(false) }
    val privacy = remember { com.inbox2.app.cloud.PrivacyStore(ctx) }
    // A proxy bearer is available (personal API key, or the signed-in mx session).
    val hasToken = remember { privacy.hasBearer() }
    // Load images privately through the Rails proxy (auto via the pref, OR the user
    // tapped the banner) AND a bearer exists. Else direct only when explicitly shown.
    val proxyMode = (privacy.proxyEnabled || showImages) && hasToken
    val directMode = showImages && !hasToken
    var attachments by remember { mutableStateOf<List<com.inbox2.app.model.AttachmentInfo>>(emptyList()) }
    var showSource by remember { mutableStateOf(false) }
    var showDetails by remember { mutableStateOf(false) }
    // Open tracking (docs/Open-Tracking.md): opens for a sent tracked message.
    var opens by remember(msg.id) { mutableStateOf<List<com.inbox2.app.engine.MessageOpen>>(emptyList()) }
    var showOpens by remember(msg.id) { mutableStateOf(false) }
    val isTracked = remember(msg.id) {
        !msg.isInbound && !msg.isDraft && (msg.bodyHTML?.let { it.contains("/o/") && it.contains(".gif") } ?: false)
    }
    LaunchedEffect(msg.id) { if (isTracked) opens = engine.messageOpens(msg.id) }
    val realOpens = opens.filter { !it.proxied }
    // False until the body web view reports its first height (its JS ran) — drives a
    // spinner over the reserved area so it never reads as blank/frozen (iOS parity).
    var bodyLoaded by remember { mutableStateOf(false) }

    // Fetch attachment metadata live when the card expands (offline/domain channels skip).
    LaunchedEffect(expanded, msg.id) {
        if (expanded && !convo.isDomain && attachments.isEmpty()) {
            attachments = engine.fetchMessage(convo.accountKey, msg.id).attachments
        }
    }
    // Meeting invite (docs/Meeting-Invites.md): MX messages carry a pre-parsed invite;
    // local-channel messages resolve it lazily from a text/calendar attachment. RSVP
    // (Accept/Tentative/Decline) writes back to the matching source.
    val calAtt = remember(attachments) {
        attachments.firstOrNull { it.mimeType == "text/calendar" || it.filename.endsWith(".ics", true) }
    }
    var localInvite by remember(msg.id) { mutableStateOf<com.inbox2.app.model.ClientInvite?>(null) }
    var rsvpStatus by remember(msg.id) { mutableStateOf(msg.invite?.answeredStatus) }
    var rsvpBusy by remember(msg.id) { mutableStateOf(false) }
    // Once answered we collapse to "You accepted · Change"; Change re-opens the buttons.
    var rsvpChanging by remember(msg.id) { mutableStateOf(false) }
    // "Add to calendar" (non-REQUEST ICS): the created event's key once added, so the
    // banner flips to a confirmation instead of offering to add it twice.
    var addedEventKey by remember(msg.id) { mutableStateOf<String?>(null) }
    /** Why the add failed, straight from the engine — shown as-is under the button. */
    var addError by remember(msg.id) { mutableStateOf<String?>(null) }
    LaunchedEffect(calAtt, msg.id) {
        if (msg.invite == null && localInvite == null && !AccountKey.isDomain(convo.accountKey)) {
            // Both shapes are kept: a REQUEST gets the RSVP pills, anything else (an
            // appointment confirmation, a booking) gets "Add to calendar". No ICS at all
            // → the meeting triage read out of the body, if any.
            (if (calAtt != null) engine.inviteFor(convo.accountKey, msg.id, calAtt.attachmentId)
             else engine.detectedInvite(convo.accountKey, msg.id))
                ?.takeIf { it.isRequest || it.isAddable }?.let {
                    localInvite = it
                    it.answeredStatus?.let { s -> rsvpStatus = s }
                    // Already on the calendar (synced, or added on an earlier read). A
                    // present-but-empty key still means added; it just has no event to
                    // deep-link to yet.
                    if (it.isAddable) it.matchedEventKey?.let { k -> addedEventKey = k }
                }
        }
    }
    val invite = msg.invite ?: localInvite
    // "Around this time" (±2h, timed events only), like the desktop InviteSchedule:
    // conflicts, and whether a detected meeting is already on the calendar.
    var nearbyEvents by remember(msg.id) { mutableStateOf<List<com.inbox2.app.model.CalendarEvent>>(emptyList()) }
    LaunchedEffect(invite) {
        val inv = invite ?: return@LaunchedEffect
        nearbyEvents = withContext(Dispatchers.IO) { eventsAround(engine.store, inv) }
    }
    fun addToCalendar() {
        if (rsvpBusy) return
        rsvpBusy = true
        addError = null
        scope.launch {
            if (msg.invite != null) {
                // MX — the API places it on the member's org calendar.
                // The thread's own org (an MX row's accountKey is its org), else the current one.
                val org = convo.accountKey.takeIf { it.startsWith("org_") } ?: cloud.activeOrg.value
                if (org == null) addError = "not signed in"
                else if (cloud.importCalendarEvent(org, msg.id)) addedEventKey = ""
                else addError = "the server couldn't add it"
            } else if (invite?.detected == true) {
                // Local detected meeting — no ICS; the core builds the event from the body.
                engine.addDetectedMeetingToCalendar(convo.accountKey, msg.id)
                    .onSuccess { addedEventKey = it }
                    .onFailure { addError = it.message ?: "unknown error" }
            } else if (calAtt != null) {
                // Local channel — write through the account's own calendar API.
                engine.addInviteToCalendar(convo.accountKey, msg.id, calAtt.attachmentId)
                    .onSuccess { addedEventKey = it }
                    .onFailure { addError = it.message ?: "unknown error" }
            }
            rsvpBusy = false
        }
    }
    fun respondInvite(resp: String) {
        if (rsvpBusy) return
        rsvpBusy = true
        scope.launch {
            val ok = if (msg.invite != null) cloud.rsvp(convo.accountKey, msg.id, resp)
            else calAtt != null && engine.respondToInvite(convo.accountKey, msg.id, calAtt.attachmentId, resp)
            if (ok) { rsvpStatus = resp; rsvpChanging = false; onInviteAnswered?.invoke() }
            rsvpBusy = false
        }
    }
    var senderMenu by remember { mutableStateOf(false) }
    Column(Modifier.insetCard().padding(Space.s3)) {
        Row(
            // Tap toggles; tap & hold the sender → copy their address (desktop: right-click).
            Modifier.fillMaxWidth().combinedClickable(
                interactionSource = remember { MutableInteractionSource() }, indication = null,
                onClick = { expanded = !expanded },
                onLongClick = { if (!msg.isDraft && msg.email.isNotEmpty()) senderMenu = true },
            ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Space.s2),
        ) {
            AvatarRing(msg.initials, 36.dp, msg.seed, email = msg.email)
            Column(Modifier.weight(1f)) {
                Text(msg.sender, color = p.textPrimary, style = AppFont.ui(14, FontWeight.SemiBold), maxLines = 1)
                Text(if (msg.isDraft) "Draft" else msg.email.ifEmpty { msg.time }, color = p.textTertiary, style = AppFont.xs2, maxLines = 1)
                androidx.compose.material3.DropdownMenu(expanded = senderMenu, onDismissRequest = { senderMenu = false }) {
                    CopyAddressRows(msg.sender, msg.email) { senderMenu = false }
                }
            }
            if (isTracked) {
                val opened = realOpens.isNotEmpty()
                val accent = if (opened) p.accentSuccess else p.textTertiary
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(3.dp),
                    modifier = Modifier.clip(RoundedCornerShape(Radius.full)).background(accent.copy(alpha = 0.14f))
                        .padding(horizontal = Space.s2, vertical = 2.dp)
                        .noRippleClickable { showOpens = !showOpens },
                ) {
                    Icon(SfIcon.vector(if (opened) "eye.fill" else "eye.slash"), null, tint = accent, modifier = Modifier.size(11.dp))
                    Text(if (opened) (if (realOpens.size > 1) "Opened ${realOpens.size}×" else "Opened") else "Sent",
                        color = accent, style = AppFont.xs3)
                }
            }
            Text(msg.time, color = p.textTertiary, style = AppFont.xs2, modifier = Modifier.padding(start = Space.s2))
            Icon(SfIcon.vector(if (expanded) "chevron.up" else "chevron.down"), null,
                tint = p.textTertiary, modifier = Modifier.padding(start = Space.s2).size(14.dp))
        }
        if (showOpens) OpenHistoryBlock(opens, p)
        if (!expanded) {
            // Collapsed cards show a 1-line preview (iOS).
            Text(
                (msg.bodyPlain ?: msg.bodyHTML ?: "").take(120).replace("\n", " "),
                color = p.textTertiary, style = AppFont.xs, maxLines = 1,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
        AnimatedVisibility(expanded) {
            Column {
                msg.meetingRequest?.let { MeetingRequestBanner(it, convo.accountKey, cloud) }
                invite?.let {
                    MeetingInviteBanner(it, rsvpStatus, rsvpBusy, rsvpChanging, { rsvpChanging = true }, ::respondInvite,
                        addedEventKey = addedEventKey, addError = addError, onAdd = ::addToCalendar,
                        nearby = nearbyEvents, onOpenEvent = onOpenEvent)
                }
                // Always-visible headers: people as tappable tokens (desktop
                // RecipientChip + ContactPopup: new message / search mail / copy
                // address) instead of raw header strings; recipient lists cap at 3
                // with a "+N more" expander.
                var showAll by remember(msg.id) { mutableStateOf(false) }
                fun composeTo(email: String) = onCompose(ComposePrefill(accountKey = convo.accountKey, to = email))
                Column(Modifier.padding(top = Space.s2), verticalArrangement = Arrangement.spacedBy(Space.s1)) {
                    AddressRow("From", com.inbox2.app.model.MailAddress.parseList(msg.fromAddress),
                        showAll, { showAll = true }, ::composeTo, onSearchSender)
                    AddressRow("To", com.inbox2.app.model.MailAddress.parseList(msg.toAddress),
                        showAll, { showAll = true }, ::composeTo, onSearchSender)
                    msg.ccAddress?.takeIf { it.isNotBlank() }?.let {
                        AddressRow("Cc", com.inbox2.app.model.MailAddress.parseList(it),
                            showAll, { showAll = true }, ::composeTo, onSearchSender)
                    }
                }
                // Attachments (fetched live) — tap to download + open with the system viewer.
                // Sit below the recipients and above the details link, mirroring desktop.
                attachments.forEach { att ->
                    var attMenu by remember(att.attachmentId) { mutableStateOf(false) }
                    fun open() = scope.launch { openAttachment(ctx, engine, convo.accountKey, msg.id, att) }
                    Box {
                        Row(
                            Modifier.fillMaxWidth().padding(top = Space.s2)
                                .clip(RoundedCornerShape(Radius.md)).background(p.bgElevated)
                                .combinedClickable(
                                    interactionSource = remember { MutableInteractionSource() }, indication = null,
                                    onClick = { open() }, onLongClick = { attMenu = true },
                                ).padding(Space.s2),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(SfIcon.vector(attachmentIcon(att.mimeType, att.filename)), null, tint = p.accentViolet, modifier = Modifier.size(24.dp))
                            Spacer(Modifier.width(Space.s2))
                            Column(Modifier.weight(1f)) {
                                Text(att.filename, color = p.textPrimary, style = AppFont.xs, maxLines = 1)
                                Text(att.sizeLabel, color = p.textTertiary, style = AppFont.xs2)
                            }
                            Icon(SfIcon.vector("tray.and.arrow.down"), "Download", tint = p.textTertiary, modifier = Modifier.size(16.dp))
                        }
                        androidx.compose.material3.DropdownMenu(expanded = attMenu, onDismissRequest = { attMenu = false }) {
                            TokenMenuRow("Open", "arrow.up.right") { attMenu = false; open() }
                            TokenMenuRow("Forward", "arrowshape.turn.up.right") {
                                attMenu = false
                                onCompose(ComposePrefill(accountKey = convo.accountKey, initialAttachments = listOf(
                                    PrefillAttachment(att.filename, att.mimeType, bytes = null,
                                        download = AttachmentRef(convo.accountKey, msg.id, att.attachmentId)))))
                            }
                            TokenMenuRow("Save to Files…", "tray.and.arrow.down") {
                                attMenu = false
                                scope.launch {
                                    val data = engine.downloadAttachment(convo.accountKey, msg.id, att.attachmentId)
                                    if (data != null) { pendingSave = data; saveLauncher.launch(att.filename) }
                                }
                            }
                        }
                    }
                }
                // Details disclosure under the tokens — reveals the date row.
                Row(
                    Modifier.padding(top = Space.s2).noRippleClickable { showDetails = !showDetails },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(if (showDetails) "Hide details" else "Details", color = p.textTertiary, style = AppFont.xs2)
                    Icon(SfIcon.vector(if (showDetails) "chevron.up" else "chevron.down"), null, tint = p.textTertiary, modifier = Modifier.size(12.dp))
                }
                // View source is tucked under expanded Details (iOS keeps the collapsed row clean).
                AnimatedVisibility(showDetails) {
                    Column(Modifier.padding(top = Space.s1), verticalArrangement = Arrangement.spacedBy(Space.s1)) {
                        DateRow(msg.createdAt)
                        if (msg.subject.isNotBlank()) DetailTextRow("Subject", msg.subject)
                        Text("View source", color = p.accentViolet, style = AppFont.xs2,
                            modifier = Modifier.padding(top = Space.s1).noRippleClickable { showSource = true })
                    }
                }
                if (blocked > 0 && !proxyMode && !directMode) {
                    Row(
                        Modifier.fillMaxWidth().padding(top = Space.s2)
                            .clip(RoundedCornerShape(Radius.md)).background(p.bgElevated)
                            .noRippleClickable { showImages = true }
                            .padding(Space.s2),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(SfIcon.vector("photo"), null, tint = p.textTertiary, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(Space.s2))
                        Text(
                            "$blocked remote image${if (blocked == 1) "" else "s"} blocked · " +
                                if (hasToken) "Load privately" else "Show images",
                            color = p.accentViolet, style = AppFont.xs,
                        )
                    }
                }
                // Graceful degradation: some image hosts (bot-managed CDNs) refuse the
                // server-side proxy outright. Offer an explicit direct load of just
                // those images — the only path that reveals the reader's IP, and only
                // to the hosts that blocked the proxy.
                if (proxyMode && proxyFailed > 0 && !loadFailedDirect) {
                    Row(
                        Modifier.fillMaxWidth().padding(top = Space.s2)
                            .clip(RoundedCornerShape(Radius.md)).background(p.bgElevated)
                            .noRippleClickable { loadFailedDirect = true }
                            .padding(Space.s2),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(SfIcon.vector("exclamationmark.triangle"), null, tint = p.textTertiary, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(Space.s2))
                        Text(
                            "$proxyFailed image${if (proxyFailed == 1) "" else "s"} couldn't load privately · Load directly",
                            color = p.accentViolet, style = AppFont.xs,
                        )
                    }
                }
                Box(Modifier.fillMaxWidth()) {
                    MessageBodyWebView(
                        html = msg.bodyForReader, showRemoteImages = directMode,
                        proxyImages = proxyMode, bearer = if (proxyMode) privacy.bearer() else null,
                        onBlockedCount = { blocked = it },
                        directFallback = loadFailedDirect,
                        onProxyFailed = { proxyFailed = it },
                        onLoaded = { bodyLoaded = true },
                        onOpenUrl = onOpenUrl,
                        modifier = Modifier.padding(top = Space.s2),
                    )
                    if (!bodyLoaded) {
                        androidx.compose.material3.CircularProgressIndicator(
                            modifier = Modifier.align(Alignment.Center).padding(Space.s4).size(20.dp),
                            color = p.accentWarmBright, strokeWidth = 2.dp,
                        )
                    }
                }
            }
        }
    }
    if (showSource) ViewSourceSheet(msg, onDismiss = { showSource = false })
}

/** A plain Details row (Subject) sharing the DateRow label column. */
@Composable
internal fun DetailTextRow(label: String, value: String) {
    val p = theme
    Row {
        Text(label, color = p.textTertiary, style = AppFont.xs2,
            modifier = Modifier.width(52.dp).padding(top = 1.dp))
        Text(value, color = p.textSecondary, style = AppFont.xs2, maxLines = 2,
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f))
    }
}

/** "Wed, Jun 10, 2026 at 9:33 AM" — date and time in the code font, "at" normal. */
@Composable
internal fun DateRow(createdAt: String, modifier: Modifier = Modifier) {
    val p = theme
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Text("Date", color = p.textTertiary, style = AppFont.xs2,
            modifier = Modifier.width(52.dp))
        val parts = com.inbox2.app.model.RelativeTime.longParts(createdAt)
        if (parts != null) {
            Text(parts.first, color = p.textSecondary, style = AppFont.mono(11))
            Text(" at ", color = p.textTertiary, style = AppFont.xs2)
            Text(parts.second, color = p.textSecondary, style = AppFont.mono(11))
        } else {
            Text(createdAt, color = p.textSecondary, style = AppFont.mono(11))
        }
        Spacer(Modifier.weight(1f))
    }
}

/** A Details row of people as tokens: label + wrapping pills, first 3 shown with a
 *  "+N more" expander (iOS MessageCard.addressRow). */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun AddressRow(
    label: String, people: List<com.inbox2.app.model.MailAddress.Parsed>,
    showAll: Boolean, onShowAll: () -> Unit,
    onCompose: (String) -> Unit, onSearch: (String) -> Unit,
) {
    if (people.isEmpty()) return
    val p = theme
    Row {
        Text(label, color = p.textTertiary, style = AppFont.xs2,
            modifier = Modifier.width(52.dp).padding(top = 3.dp))
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(Space.s1 + 2.dp),
            verticalArrangement = Arrangement.spacedBy(Space.s1),
        ) {
            val visible = if (showAll) people else people.take(3)
            visible.forEach { person -> AddressToken(person, onCompose, onSearch) }
            if (!showAll && people.size > 3) {
                Text("+${people.size - 3} more", color = p.accentViolet, style = AppFont.xs2,
                    modifier = Modifier.clip(RoundedCornerShape(Radius.full))
                        .background(p.accentViolet.copy(alpha = 0.13f))
                        .noRippleClickable { onShowAll() }
                        .padding(horizontal = Space.s2 + 2.dp, vertical = 3.dp))
            }
        }
    }
}

/** Copy address / Copy name and address — the address-token menu and the
 *  long-press menu on the card's sender header. */
@Composable
internal fun CopyAddressRows(name: String, email: String, dismiss: () -> Unit) {
    val clipboard = androidx.compose.ui.platform.LocalClipboardManager.current
    TokenMenuRow("Copy address", "doc.on.doc") {
        dismiss(); clipboard.setText(androidx.compose.ui.text.AnnotatedString(email))
    }
    if (name.isNotEmpty() && name != email) TokenMenuRow("Copy name and address", "person.crop.circle") {
        dismiss(); clipboard.setText(androidx.compose.ui.text.AnnotatedString("$name <$email>"))
    }
}

/** One person as a pill; tap or tap & hold opens a menu titled with the address:
 *  New message / Search mail / Copy address (the desktop ContactPopup actions). */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
internal fun AddressToken(
    person: com.inbox2.app.model.MailAddress.Parsed,
    onCompose: (String) -> Unit, onSearch: (String) -> Unit,
) {
    val p = theme
    var menu by remember { mutableStateOf(false) }
    Box {
        Text(person.name.ifEmpty { person.email }, color = p.textSecondary, style = AppFont.xs2, maxLines = 1,
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
            modifier = Modifier.clip(RoundedCornerShape(Radius.full)).background(p.bgElevated)
                .combinedClickable(
                    interactionSource = remember { MutableInteractionSource() }, indication = null,
                    onClick = { menu = true }, onLongClick = { menu = true },
                )
                .padding(horizontal = Space.s2 + 2.dp, vertical = 3.dp))
        androidx.compose.material3.DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            androidx.compose.material3.DropdownMenuItem(enabled = false,
                text = { Text(person.email, color = p.textTertiary, style = AppFont.xs2) }, onClick = {})
            TokenMenuRow("New message", "square.and.pencil") { menu = false; onCompose(person.email) }
            TokenMenuRow("Search mail", "magnifyingglass") { menu = false; onSearch(person.email) }
            CopyAddressRows(person.name, person.email) { menu = false }
        }
    }
}

@Composable
internal fun TokenMenuRow(label: String, icon: String, onClick: () -> Unit) {
    val p = theme
    androidx.compose.material3.DropdownMenuItem(
        text = { Text(label, color = p.textPrimary, style = AppFont.sm) },
        leadingIcon = { Icon(SfIcon.vector(icon), null, tint = p.textPrimary, modifier = Modifier.size(18.dp)) },
        onClick = onClick,
    )
}

internal fun attachmentIcon(mime: String, filename: String): String {
    val m = mime.lowercase()
    val ext = filename.substringAfterLast('.', "").lowercase()
    return when {
        m.startsWith("image/") -> "photo"
        m.contains("pdf") || ext == "pdf" -> "doc.richtext"
        m.startsWith("video/") -> "video"
        m.startsWith("audio/") -> "music.note"
        m.contains("zip") || m.contains("compressed") || ext in setOf("zip", "gz", "7z", "rar", "tar") -> "doc.zipper"
        m.contains("spreadsheet") || m.contains("excel") || ext in setOf("csv", "xls", "xlsx", "numbers") -> "tablecells"
        m.contains("presentation") || m.contains("powerpoint") || ext in setOf("ppt", "pptx", "key") -> "rectangle.on.rectangle"
        m.contains("msword") || m.contains("wordprocessing") || ext in setOf("doc", "docx", "pages", "rtf", "odt") -> "doc.text"
        m == "text/calendar" || ext == "ics" -> "calendar"
        m.startsWith("text/") || ext in setOf("txt", "md", "log", "json", "xml", "html") -> "doc.plaintext"
        else -> "doc"
    }
}

private suspend fun openAttachment(
    ctx: android.content.Context, engine: EngineModel, accountKey: String, messageKey: String,
    att: com.inbox2.app.model.AttachmentInfo,
) {
    val bytes = engine.downloadAttachment(accountKey, messageKey, att.attachmentId) ?: return
    withContext(Dispatchers.IO) {
        val dir = java.io.File(ctx.cacheDir, "attachments").apply { mkdirs() }
        // Strip any path component from the server/email-supplied filename and confirm the
        // resolved file stays inside the attachments dir (path-traversal defence).
        val safeName = java.io.File(att.filename).name
            .takeIf { it.isNotBlank() && it != "." && it != ".." } ?: "attachment"
        val file = java.io.File(dir, safeName)
        if (!file.canonicalPath.startsWith(dir.canonicalPath + java.io.File.separator)) return@withContext
        file.writeBytes(bytes)
        val uri = androidx.core.content.FileProvider.getUriForFile(ctx, "${ctx.packageName}.fileprovider", file)
        val intent = android.content.Intent(android.content.Intent.ACTION_VIEW).apply {
            setDataAndType(uri, att.mimeType.ifBlank { "*/*" })
            addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        runCatching { ctx.startActivity(intent) }
    }
}
