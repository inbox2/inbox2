package com.inbox2.app.ui.screens

import com.inbox2.app.ui.components.DatePick
import com.inbox2.app.ui.components.PillTextButton
import com.inbox2.app.ui.components.TimePick
import com.inbox2.app.model.byteSizeLabel
import com.inbox2.app.model.MailAddress
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.inbox2.app.engine.DraftStore
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.engine.SavedDraft
import com.inbox2.app.model.Contact
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.darkKeycap
import com.inbox2.app.ui.components.domeKeycap
import com.inbox2.app.ui.components.pastelChip
import com.inbox2.app.ui.components.ScreenHeader
import com.inbox2.app.ui.components.SfIcon
import com.inbox2.app.ui.components.noRippleClickable
import kotlinx.coroutines.launch
import uniffi.inbox2_core.FfiAttachment

/** Prefilled compose state (reply/forward/new/draft-resume). */
data class ComposePrefill(
    val accountKey: String? = null,
    val to: String = "",
    val cc: String = "",
    val bcc: String = "",
    val subject: String = "",
    val body: String = "",
    val conversationId: String? = null,   // set for a domain (mx) threaded reply
    val savedDraftId: String? = null,      // set when resuming a local draft
    /** Set for an engine reply: local key of the message being replied to — the
     *  engine hydrates In-Reply-To/References (+ Gmail threadId) from it so the
     *  reply threads for us and for every recipient. */
    val replyToMessageKey: String? = null,
    /** The thread being replied to (any channel) — marked read once the reply is sent. */
    val conversationKey: String? = null,
    /** Send from this exact address instead of the identity's (a domain reply goes out
     *  from the address the thread arrived at). */
    val fromEmailOverride: String? = null,
    /** Attachments pre-loaded by the caller — e.g. files shared in via an ACTION_SEND
     *  "Send to inbox2" (RootTabs reads the content-URI bytes before opening compose). */
    val initialAttachments: List<PrefillAttachment> = emptyList(),
)

/** An attachment handed to compose via [ComposePrefill]. Either the bytes are
 *  already read (shared-in files), or `download` points at a provider attachment
 *  that the composer fetches in-screen (Forward) — a plain class, not a data class
 *  (ByteArray has no meaningful value equality). */
class PrefillAttachment(
    val name: String,
    val mime: String,
    val bytes: ByteArray? = null,
    val download: AttachmentRef? = null,
)

/** Points at a provider attachment to fetch its bytes (cached) in the composer. */
data class AttachmentRef(val accountKey: String, val messageKey: String, val attachmentId: String)

private data class Identity(
    val key: String,
    val email: String,
    val label: String,
    /** Provider slug for the channel logo; null for a domain (inbox2) identity. */
    val provider: String? = null,
)
/** A composer attachment: resolved bytes, or a pending `download` the composer
 *  fetches in-screen (spinner shown, Send blocked until it lands). */
private class Att(
    val name: String,
    val mime: String,
    val bytes: ByteArray? = null,
    val download: AttachmentRef? = null,
    val failed: Boolean = false,
) {
    val pending get() = bytes == null && download != null && !failed
}

private fun tomorrow9am(): Long = java.util.Calendar.getInstance().apply {
    add(java.util.Calendar.DAY_OF_YEAR, 1)
    set(java.util.Calendar.HOUR_OF_DAY, 9); set(java.util.Calendar.MINUTE, 0)
    set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0)
}.timeInMillis

/** Compose (iOS ComposeView): From-identity picker (offline + domain), To/Cc/Bcc with
 *  contact autocomplete, Subject, attachments, body, send → outbox (or the cloud API for
 *  a domain identity), Save-draft/Discard on cancel, resume a saved draft. */
@Composable
fun ComposeScreen(engine: EngineModel, cloud: com.inbox2.app.cloud.CloudSession, prefill: ComposePrefill, onClose: () -> Unit, onDomainSent: () -> Unit = {}) {
    val p = theme
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val accounts by engine.accounts.collectAsState()
    val cloudUser by cloud.user.collectAsState()
    val orgs by cloud.orgs.collectAsState()
    val drafts = remember { DraftStore(ctx) }
    // contacts() is an unbounded full-table scan + address parse — load it off the main
    // thread (its first, uncached call would otherwise block the UI on a large store).
    var contacts by remember { mutableStateOf<List<Contact>>(emptyList()) }
    LaunchedEffect(Unit) {
        contacts = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { engine.store.contacts() }
    }

    val identities = remember(accounts, cloudUser, orgs) {
        buildList {
            accounts.forEach { add(Identity(it.id, it.email, it.email, it.provider)) }
            // The server's send-as list (all share the org key); older payloads lack it
            // → username@ the org's domain.
            cloudUser?.let { u ->
                orgs.forEach { o ->
                    o.fromAddresses?.forEach { add(Identity(o.id, it, "$it · ${o.name}")) }
                        ?: o.domain?.takeIf { it.isNotBlank() }?.let { d -> add(Identity(o.id, "${u.username}@$d", "${u.username}@$d · ${o.name}")) }
                }
            }
        }
    }
    // Explicit (a reply, or the inbox's filtered account) → the one last sent from → the first.
    val defaults = remember { ctx.getSharedPreferences("inbox2_defaults", android.content.Context.MODE_PRIVATE) }
    var fromKey by remember { mutableStateOf(prefill.accountKey) }
    // Domain identities can arrive after first composition (orgs load on restore), so
    // resolve the default whenever the list changes and the current pick isn't in it.
    LaunchedEffect(identities) {
        if (identities.none { it.key == fromKey }) {
            val last = defaults.getString("last_from_key", null)
            fromKey = identities.firstOrNull { it.key == prefill.accountKey }?.key
                ?: identities.firstOrNull { it.key == last }?.key ?: identities.firstOrNull()?.key
        }
    }
    var to by remember { mutableStateOf(prefill.to) }
    var cc by remember { mutableStateOf(prefill.cc) }
    var bcc by remember { mutableStateOf(prefill.bcc) }
    var subject by remember { mutableStateOf(prefill.subject) }
    var body by remember { mutableStateOf(prefill.body) }
    var showCcBcc by remember { mutableStateOf(prefill.cc.isNotEmpty() || prefill.bcc.isNotEmpty()) }
    var sending by remember { mutableStateOf(false) }
    var statusMsg by remember { mutableStateOf<String?>(null) }
    var attachMenu by remember { mutableStateOf(false) }
    var fromMenu by remember { mutableStateOf(false) }
    var confirmCancel by remember { mutableStateOf(false) }
    val attachments = remember {
        mutableStateListOf<Att>().apply {
            addAll(prefill.initialAttachments.map { Att(it.name, it.mime, it.bytes, it.download) })
        }
    }

    // Resolve pending forward attachments in-screen: download each one's bytes
    // (cached in EngineModel) and swap it in. Spinner shows while pending; Send is
    // blocked (`hasPending`) until every one lands.
    LaunchedEffect(Unit) {
        attachments.filter { it.pending }.forEach { att ->
            val dl = att.download ?: return@forEach
            val data = engine.downloadAttachment(dl.accountKey, dl.messageKey, dl.attachmentId)
            val idx = attachments.indexOfFirst { it === att }
            if (idx >= 0) {
                attachments[idx] = if (data != null) Att(att.name, att.mime, data)
                                   else Att(att.name, att.mime, null, att.download, failed = true)
            }
        }
    }
    val hasPending by remember { derivedStateOf { attachments.any { it.pending } } }

    // The exact address picked: an org's own and shared addresses share one key.
    var pickedEmail by remember { mutableStateOf<String?>(null) }
    val fromIdentity = identities.firstOrNull { it.key == fromKey && (pickedEmail == null || it.email == pickedEmail) }
        ?: identities.firstOrNull { it.key == fromKey }
    // A reply/forward's exact From only holds while its own account is picked (iOS parity).
    val fromEmail = pickedEmail ?: prefill.fromEmailOverride?.takeIf { fromKey == prefill.accountKey } ?: fromIdentity?.email ?: ""
    // The From address's signature (domain mail only); Remove takes it off this message.
    var signature by remember { mutableStateOf<com.inbox2.app.model.MailSignature?>(null) }
    var signatureOff by remember { mutableStateOf(false) }
    LaunchedEffect(fromKey, fromEmail) {
        val key = fromKey
        signature = if (key != null && com.inbox2.app.model.AccountKey.isDomain(key) && fromEmail.isNotEmpty()) cloud.signature(key, fromEmail) else null
    }
    val hasContent = to.isNotBlank() || cc.isNotBlank() || bcc.isNotBlank() || subject.isNotBlank() || body.isNotBlank() || attachments.isNotEmpty()

    /// Read a picked content URI into an attachment chip (shared by the file and photo
    /// pickers — the photo picker returns the same kind of URI, just from a different UI).
    fun attachFrom(uri: android.net.Uri, fallbackName: String) {
        runCatching {
            val cr = ctx.contentResolver
            val name = cr.query(uri, null, null, null, null)?.use { c ->
                val i = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                if (i >= 0 && c.moveToFirst()) c.getString(i) else null
            } ?: fallbackName
            val mime = cr.getType(uri) ?: "application/octet-stream"
            val bytes = cr.openInputStream(uri)?.use { it.readBytes() } ?: ByteArray(0)
            attachments.add(Att(name, mime, bytes))
        }.onFailure {
            // A picked file that silently never appears is the worst outcome — say so.
            statusMsg = "Couldn't attach that file. Try again."
        }
    }

    // Both pickers take several at once (iOS allows multi-select in Files and Photos).
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetMultipleContents()) { uris ->
        uris.forEach { attachFrom(it, "attachment") }
    }
    // The system photo picker: no storage permission, and it only ever hands back what
    // the user actually selected (iOS PhotosPicker's counterpart).
    val photoPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { uris ->
        uris.forEach { attachFrom(it, "photo.jpg") }
    }
    // Camera capture writes into the cache dir the existing FileProvider already exports,
    // so this needs no manifest change — and no CAMERA permission, since ACTION_IMAGE_CAPTURE
    // is handled by the camera app (declaring the permission would only make it required).
    var cameraUri by remember { mutableStateOf<android.net.Uri?>(null) }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        val uri = cameraUri
        cameraUri = null
        if (ok && uri != null) attachFrom(uri, "photo.jpg")
    }
    fun launchCamera() {
        runCatching {
            val dir = java.io.File(ctx.cacheDir, "attachments").apply { mkdirs() }
            val file = java.io.File(dir, "photo-${System.currentTimeMillis()}.jpg")
            val uri = androidx.core.content.FileProvider.getUriForFile(ctx, "${ctx.packageName}.fileprovider", file)
            cameraUri = uri
            camera.launch(uri)
        }.onFailure { statusMsg = "No camera available" }
    }

    fun close() = onClose()
    fun saveDraftAndClose() {
        val id = prefill.savedDraftId ?: "draft_${System.nanoTime()}"
        drafts.save(SavedDraft(id, fromKey, to, cc, subject, body, bcc))
        engine.bumpDataVersion()
        close()
    }
    // System back with content behaves like Cancel: the same dialog asks what to do
    // (iOS refuses the swipe-down and shows it). Composed after the shell's handler, so
    // it wins while the composer is up.
    androidx.activity.compose.BackHandler { if (hasContent) confirmCancel = true else close() }

    /** Sent a reply → the thread is read (iOS markThreadRead). */
    fun markThreadRead(key: String) {
        prefill.conversationKey?.let { ck -> scope.launch { engine.performRouted(cloud, key, listOf(ck), com.inbox2.app.model.ConversationAction.MarkRead.verb) } }
    }

    val isDomainFrom = com.inbox2.app.model.AccountKey.isDomain(fromKey ?: "")

    fun doSend() {
        val key = fromKey ?: return
        defaults.edit().putString("last_from_key", key).apply()
        sending = true
        scope.launch {
            if (com.inbox2.app.model.AccountKey.isDomain(key)) {
                val atts = attachments.mapNotNull { att -> att.bytes?.let { com.inbox2.app.cloud.OutgoingAttachment(att.name, att.mime, it) } }
                val res = runCatching { cloud.send(key, prefill.conversationId, fromEmail, to, cc.ifBlank { null }, subject, body, atts, signature.takeUnless { signatureOff }) }
                sending = false
                if (res.isSuccess) { prefill.savedDraftId?.let(drafts::delete); markThreadRead(key); onDomainSent(); close() }
                else statusMsg = "Couldn't send: ${res.exceptionOrNull()?.message}"
            } else {
                val ffi = attachments.mapNotNull { att -> att.bytes?.let { FfiAttachment(att.name, att.mime, it) } }
                val (ok, status) = engine.send(
                    accountKey = key, from = fromIdentity?.email ?: "",
                    to = to, cc = cc.ifBlank { null }, bcc = bcc.ifBlank { null },
                    subject = subject, bodyPlain = body, attachments = ffi,
                    replyToMessageKey = prefill.replyToMessageKey,
                )
                sending = false
                statusMsg = if (ok) "Message $status" else "Couldn't send ($status)"
                if (ok) { prefill.savedDraftId?.let(drafts::delete); markThreadRead(key); close() }
            }
        }
    }
    fun doSchedule(sendAtMs: Long) {
        val key = fromKey ?: return
        sending = true
        scope.launch {
            val iso = java.time.format.DateTimeFormatter.ISO_OFFSET_DATE_TIME.format(
                java.time.Instant.ofEpochMilli(sendAtMs).atZone(java.time.ZoneId.systemDefault()))
            val atts = attachments.mapNotNull { att -> att.bytes?.let { com.inbox2.app.cloud.OutgoingAttachment(att.name, att.mime, it) } }
            val ok = cloud.scheduleNewSend(key, prefill.conversationId, fromEmail, to, cc.ifBlank { null }, subject, body, iso, atts, signature.takeUnless { signatureOff })
            sending = false
            if (ok) { prefill.savedDraftId?.let(drafts::delete); markThreadRead(key); close() } else statusMsg = "Couldn't schedule"
        }
    }

    Column(Modifier.fillMaxSize().background(p.bgBase).verticalScroll(rememberScrollState())) {
        // iOS sheet-style header: Cancel · centered "New message" · paperplane send.
        Box(Modifier.fillMaxWidth().padding(horizontal = Space.s4, vertical = Space.s3)) {
            Text("New message", color = p.textPrimary, style = AppFont.ui(16, FontWeight.SemiBold),
                maxLines = 1, modifier = Modifier.align(Alignment.Center))
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("Cancel", color = p.accentViolet, style = AppFont.md,
                    modifier = Modifier.noRippleClickable { if (hasContent) confirmCancel = true else close() })
                Spacer(Modifier.weight(1f))
                val canSend = to.isNotBlank() && fromKey != null && !sending && !hasPending
                var sendMenu by remember { mutableStateOf(false) }
                var schedulePickDate by remember { mutableStateOf(false) }
                var schedulePickTime by remember { mutableStateOf(false) }
                var scheduleMs by remember { mutableStateOf(0L) }
                Box {
                    if (sending) CircularProgressIndicator(color = p.accentViolet, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
                    else if (p.groove != null) Box(
                        // Groovebox: send is the lavender dome (a dark key while it can't send).
                        Modifier.size(40.dp)
                            .then(if (canSend) Modifier.domeKeycap(p.groove) else Modifier.darkKeycap(p.groove))
                            .noRippleClickable(enabled = canSend) { if (isDomainFrom) sendMenu = true else doSend() }
                            .padding(bottom = 2.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(SfIcon.vector("paperplane.fill"), "Send", tint = if (canSend) p.onAccent else p.textTertiary,
                            modifier = Modifier.size(18.dp))
                    }
                    else Icon(
                        SfIcon.vector("paperplane.fill"), "Send",
                        tint = if (canSend) p.accentViolet else p.textTertiary,
                        modifier = Modifier.size(22.dp).noRippleClickable(enabled = canSend) { if (isDomainFrom) sendMenu = true else doSend() },
                    )
                    if (isDomainFrom) com.inbox2.app.ui.components.GlassDropdownMenu(sendMenu, onDismissRequest = { sendMenu = false }) {
                        DropdownMenuItem(text = { Text("Send now", color = p.textPrimary, style = AppFont.sm) }, onClick = { sendMenu = false; doSend() })
                        DropdownMenuItem(text = { Text("Schedule · in 1 hour", color = p.textPrimary, style = AppFont.sm) },
                            onClick = { sendMenu = false; doSchedule(System.currentTimeMillis() + 3600_000) })
                        DropdownMenuItem(text = { Text("Schedule · tomorrow 9am", color = p.textPrimary, style = AppFont.sm) },
                            onClick = { sendMenu = false; doSchedule(tomorrow9am()) })
                        DropdownMenuItem(text = { Text("Schedule · pick a time…", color = p.textPrimary, style = AppFont.sm) },
                            onClick = { sendMenu = false; scheduleMs = System.currentTimeMillis() + 3600_000; schedulePickDate = true })
                    }
                    // Pick an arbitrary send time (iOS free DatePicker): choose the day, then
                    // the time, then schedule. Reuses the calendar sheet's pickers.
                    if (schedulePickDate) DatePick(scheduleMs) { picked ->
                        schedulePickDate = false
                        if (picked != null) { scheduleMs += dayOnly(picked) - dayOnly(scheduleMs); schedulePickTime = true }
                    }
                    if (schedulePickTime) TimePick(scheduleMs) { picked ->
                        schedulePickTime = false
                        if (picked != null && picked > System.currentTimeMillis()) doSchedule(picked)
                        else if (picked != null) statusMsg = "Pick a later time"
                    }
                }
            }
        }

        // From identity picker (offline accounts + domain identities).
        FieldRow("From") {
            Box {
                Row(verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Space.s2),
                    modifier = Modifier.noRippleClickable { fromMenu = true }) {
                    // The channel's own mark, so the row reads as a channel and not
                    // just an address (iOS ComposeView + the desktop From picker).
                    fromIdentity?.let { IdentityMark(it, 18.dp) }
                    Text(fromEmail.ifEmpty { "(no account)" }, color = p.textPrimary, style = AppFont.sm)
                    if (identities.size > 1) Icon(SfIcon.vector("chevron.down"), null, tint = p.textTertiary, modifier = Modifier.size(16.dp))
                }
                com.inbox2.app.ui.components.GlassDropdownMenu(fromMenu, onDismissRequest = { fromMenu = false }) {
                    identities.forEach { id ->
                        DropdownMenuItem(
                            text = { Text(id.label, color = p.textPrimary, style = AppFont.sm) },
                            leadingIcon = { IdentityMark(id, 20.dp) },
                            onClick = { fromKey = id.key; pickedEmail = id.email; fromMenu = false },
                        )
                    }
                }
            }
        }
        // "Add Cc/Bcc" rides the trailing end of the attach row below (iOS parity), so it
        // costs no row of its own and can't collide with a wrapped list of To chips.
        RecipientField("To", to, { to = it }, contacts, "name@example.com")
        if (showCcBcc) {
            RecipientField("Cc", cc, { cc = it }, contacts, "")
            RecipientField("Bcc", bcc, { bcc = it }, contacts, "")
        }
        FieldRow("Subject") { ComposeField(subject, { subject = it }, "Subject", KeyboardOptions(capitalization = androidx.compose.ui.text.input.KeyboardCapitalization.Sentences)) }

        // Attachments. The Cc/Bcc reveal is one-way, so once it's open this is just
        // the attach action again.
        FieldRow("Attach") {
            Box {
                Text("+ Add", color = p.accentViolet, style = AppFont.sm,
                    modifier = Modifier.noRippleClickable { attachMenu = true })
                com.inbox2.app.ui.components.GlassDropdownMenu(attachMenu, onDismissRequest = { attachMenu = false }) {
                    DropdownMenuItem(text = { Text("Files", color = p.textPrimary, style = AppFont.sm) },
                        onClick = { attachMenu = false; picker.launch("*/*") })
                    DropdownMenuItem(text = { Text("Photos", color = p.textPrimary, style = AppFont.sm) },
                        onClick = {
                            attachMenu = false
                            photoPicker.launch(androidx.activity.result.PickVisualMediaRequest(
                                ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                        })
                    DropdownMenuItem(text = { Text("Camera", color = p.textPrimary, style = AppFont.sm) },
                        onClick = { attachMenu = false; launchCamera() })
                }
            }
            Spacer(Modifier.weight(1f))
            if (!showCcBcc) {
                Text("Add Cc/Bcc", color = p.accentViolet, style = AppFont.sm,
                    modifier = Modifier.noRippleClickable { showCcBcc = true })
            }
        }
        attachments.forEachIndexed { i, att ->
            Row(Modifier.fillMaxWidth().padding(horizontal = Space.s4, vertical = 2.dp).alpha(if (att.pending) 0.7f else 1f), verticalAlignment = Alignment.CenterVertically) {
                if (att.pending) {
                    CircularProgressIndicator(color = p.accentViolet, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                } else {
                    Icon(SfIcon.vector("paperclip"), null, tint = p.textTertiary, modifier = Modifier.size(16.dp))
                }
                Spacer(Modifier.width(Space.s2))
                Text(att.name, color = p.textSecondary, style = AppFont.xs, modifier = Modifier.weight(1f), maxLines = 1)
                att.bytes?.let { Text(byteSizeLabel(it.size), color = p.textTertiary, style = AppFont.xs2, modifier = Modifier.padding(end = Space.s2)) }
                if (att.failed) Text("failed", color = p.textTertiary, style = AppFont.xs2, modifier = Modifier.padding(end = Space.s2))
                Icon(SfIcon.vector("xmark"), "Remove", tint = p.textTertiary,
                    modifier = Modifier.size(16.dp).noRippleClickable { attachments.removeAt(i) })
            }
        }

        Box(
            Modifier.fillMaxWidth().padding(Space.s4).clip(RoundedCornerShape(if (p.groove != null) Radius.xl else Radius.lg))
                .background(p.bgInput).padding(Space.s3).heightIn(min = 200.dp),
        ) {
            if (body.isEmpty()) Text("Write your message…", color = p.textTertiary, style = AppFont.body)
            BasicTextField(
                value = body, onValueChange = { body = it },
                textStyle = AppFont.body.copy(color = p.textPrimary),
                keyboardOptions = KeyboardOptions(capitalization = androidx.compose.ui.text.input.KeyboardCapitalization.Sentences),
                cursorBrush = SolidColor(p.accentViolet), modifier = Modifier.fillMaxWidth(),
            )
        }
        signature?.let { sig ->
            Column(Modifier.fillMaxWidth().padding(horizontal = Space.s4 + Space.s3)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Signature", color = p.textTertiary, style = AppFont.xs, modifier = Modifier.weight(1f))
                    Text(if (signatureOff) "Add signature" else "Remove", color = p.accentViolet, style = AppFont.xs,
                        modifier = Modifier.noRippleClickable { signatureOff = !signatureOff })
                }
                if (!signatureOff) Text(sig.previewText, color = p.textSecondary, style = AppFont.sm, modifier = Modifier.padding(top = Space.s1))
            }
        }
        statusMsg?.let { Text(it, color = if (it.startsWith("Couldn't")) p.accentDanger else p.textTertiary, style = AppFont.xs, modifier = Modifier.padding(Space.s4)) }
        Spacer(Modifier.height(40.dp))
    }

    if (confirmCancel) {
        AlertDialog(
            onDismissRequest = { confirmCancel = false },
            title = { Text("Save draft?") },
            confirmButton = { PillTextButton("Save draft") { confirmCancel = false; saveDraftAndClose() } },
            dismissButton = {
                Row {
                    PillTextButton("Discard") { confirmCancel = false; prefill.savedDraftId?.let(drafts::delete); close() }
                    PillTextButton("Keep editing") { confirmCancel = false }
                }
            },
        )
    }
}

/** Groovebox: a header field sits in its own #1b1b1f well (the divider goes away). */
@Composable
private fun Modifier.grooveWell(): Modifier {
    val p = theme
    return if (p.groove == null) this
    else this.padding(horizontal = Space.s3, vertical = 3.dp).clip(RoundedCornerShape(Radius.lg)).background(p.bgInput)
}

@Composable
private fun FieldRow(label: String, content: @Composable RowScope.() -> Unit) {
    val p = theme
    Column {
        Row(
            Modifier.fillMaxWidth().grooveWell().padding(horizontal = Space.s4, vertical = Space.s3),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(label, color = p.textTertiary, style = AppFont.sm, modifier = Modifier.width(64.dp))
            content()
        }
        if (p.groove == null) androidx.compose.material3.HorizontalDivider(color = p.borderSubtle, thickness = 0.5.dp,
            modifier = Modifier.padding(start = Space.s4))
    }
}

@Composable
private fun RowScope.ComposeField(value: String, onChange: (String) -> Unit, placeholder: String, keyboardOptions: KeyboardOptions = KeyboardOptions.Default) {
    val p = theme
    Box(Modifier.weight(1f)) {
        if (value.isEmpty()) Text(placeholder, color = p.textTertiary, style = AppFont.sm)
        BasicTextField(
            value = value, onValueChange = onChange, singleLine = true, keyboardOptions = keyboardOptions,
            textStyle = AppFont.sm.copy(color = p.textPrimary), cursorBrush = SolidColor(p.accentViolet),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

/** A tokenized recipient field (matches iOS RecipientTokenField): committed addresses
 *  render as chips showing the contact display name, each with a tap menu (Copy / Remove);
 *  an inline field captures the next address with contact autocomplete. A leading
 *  zero-width-space sentinel makes a backspace on the empty field delete the last chip
 *  (Compose, like UIKit, gives no backspace-on-empty event otherwise). Writes back to the
 *  comma-separated `value` so the send path is unchanged. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun RecipientField(label: String, value: String, onChange: (String) -> Unit, contacts: List<Contact>, placeholder: String) {
    val p = theme
    val clipboard = LocalClipboardManager.current
    val zwsp = "\u200B"
    val chips = remember {
        mutableStateListOf<String>().apply { addAll(MailAddress.splitList(value).map { it.trim() }.filter { it.isNotEmpty() }) }
    }
    var raw by remember { mutableStateOf(zwsp) }   // field content, always sentinel-prefixed
    var focused by remember { mutableStateOf(false) }
    var menuFor by remember { mutableStateOf<String?>(null) }
    val draft = raw.removePrefix(zwsp)

    fun writeBack(d: String) {
        val t = d.trim()
        onChange((chips + if (t.isEmpty()) emptyList() else listOf(t)).joinToString(", "))
    }
    fun addChip(s: String) {
        val t = s.trim()
        if (t.isNotEmpty() && chips.none { recipientAddress(it).equals(recipientAddress(t), true) }) chips.add(t)
    }

    val token = draft.trim()
    val suggestions = if (focused && token.length >= 2) contacts.filter {
        it.email.contains(token, true) || it.name.contains(token, true)
    }.filter { c -> chips.none { recipientAddress(it).equals(c.email, true) } }.take(5) else emptyList()

    Column {
        Row(
            Modifier.fillMaxWidth().grooveWell().padding(horizontal = Space.s4, vertical = Space.s3),
            verticalAlignment = Alignment.Top,
        ) {
            Text(label, color = p.textTertiary, style = AppFont.sm, modifier = Modifier.width(64.dp).padding(top = 6.dp))
            Column(Modifier.weight(1f)) {
                if (chips.isNotEmpty()) {
                    FlowRow(
                        Modifier.padding(bottom = 4.dp),
                        horizontalArrangement = Arrangement.spacedBy(Space.s1),
                        verticalArrangement = Arrangement.spacedBy(Space.s1),
                    ) {
                        chips.forEach { chip ->
                            Box {
                                val g = p.groove   // Groovebox: a solid pastel chip with dark ink
                                Row(
                                    (if (g != null) Modifier.pastelChip(g.pastelFor(recipientAddress(chip)), g) else Modifier)
                                        .clip(RoundedCornerShape(Radius.full))
                                        .then(if (g == null) Modifier.background(p.bgRaised) else Modifier)
                                        .noRippleClickable { menuFor = chip }
                                        .padding(start = Space.s2, end = 6.dp, top = 3.dp, bottom = if (g != null) 5.dp else 3.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(3.dp),
                                ) {
                                    Text(chipDisplay(chip, contacts), color = g?.chipInk ?: p.textPrimary, style = AppFont.xs, maxLines = 1)
                                    Icon(SfIcon.vector("chevron.down"), null, tint = g?.chipInk ?: p.textTertiary, modifier = Modifier.size(9.dp))
                                }
                                com.inbox2.app.ui.components.GlassDropdownMenu(expanded = menuFor == chip, onDismissRequest = { menuFor = null }) {
                                    Text(recipientAddress(chip), color = p.textTertiary, style = AppFont.xs,
                                        modifier = Modifier.padding(horizontal = Space.s3, vertical = Space.s2))
                                    DropdownMenuItem(
                                        text = { Text("Copy address", color = p.textPrimary, style = AppFont.sm) },
                                        leadingIcon = { Icon(SfIcon.vector("doc.on.doc"), null, tint = p.textSecondary, modifier = Modifier.size(18.dp)) },
                                        onClick = { clipboard.setText(AnnotatedString(recipientAddress(chip))); menuFor = null },
                                    )
                                    DropdownMenuItem(
                                        text = { Text("Remove", color = p.accentDanger, style = AppFont.sm) },
                                        leadingIcon = { Icon(SfIcon.vector("trash"), null, tint = p.accentDanger, modifier = Modifier.size(18.dp)) },
                                        onClick = { chips.remove(chip); writeBack(draft); menuFor = null },
                                    )
                                }
                            }
                        }
                    }
                }
                Box {
                    if (draft.isEmpty() && chips.isEmpty()) Text(placeholder, color = p.textTertiary, style = AppFont.sm)
                    BasicTextField(
                        value = raw,
                        onValueChange = { v ->
                            if (v.isEmpty()) {                       // backspaced past the sentinel
                                if (chips.isNotEmpty()) chips.removeAt(chips.lastIndex)
                                raw = zwsp
                                writeBack("")
                            } else {
                                var s = v.removePrefix(zwsp)
                                val parts = MailAddress.splitList(s)
                                if (parts.size > 1) {               // comma commits the token(s)
                                    parts.dropLast(1).forEach { addChip(it) }
                                    s = parts.last().trim()
                                }
                                raw = zwsp + s
                                writeBack(s)
                            }
                        },
                        singleLine = true,
                        textStyle = AppFont.sm.copy(color = p.textPrimary),
                        cursorBrush = SolidColor(p.accentViolet),
                        keyboardOptions = KeyboardOptions(autoCorrect = false, keyboardType = KeyboardType.Email, imeAction = ImeAction.Next),
                        keyboardActions = KeyboardActions(onNext = {
                            if (draft.trim().isNotEmpty()) { addChip(draft); raw = zwsp; writeBack("") }
                        }),
                        modifier = Modifier.fillMaxWidth().onFocusChanged { focused = it.isFocused },
                    )
                }
            }
        }
        suggestions.forEach { c ->
            Column(
                Modifier.fillMaxWidth().noRippleClickable { addChip(c.formatted); raw = zwsp; writeBack("") }
                    .padding(start = 80.dp, end = Space.s4, top = 4.dp, bottom = 4.dp),
            ) {
                Text(if (c.name.isEmpty()) c.email else c.name, color = p.textPrimary, style = AppFont.sm)
                if (c.name.isNotEmpty()) Text(c.email, color = p.textTertiary, style = AppFont.xs)
            }
        }
        if (p.groove == null) androidx.compose.material3.HorizontalDivider(color = p.borderSubtle, thickness = 0.5.dp,
            modifier = Modifier.padding(start = Space.s4))
    }
}

/** The bare address from a "Name <email>" token, or the trimmed string itself. */
private fun recipientAddress(s: String): String = MailAddress.parse(s).email

/** A chip's friendly label: the contact name (matched by address), else any parsed name,
 *  else the bare address. */
private fun chipDisplay(chip: String, contacts: List<Contact>): String {
    val parsed = MailAddress.parse(chip)
    contacts.firstOrNull { it.email.equals(parsed.email, true) && it.name.isNotEmpty() }?.let { return it.name }
    return parsed.name
}

/** A From identity's channel mark: the provider's brand logo, or the inbox2 tile
 *  for a domain address (ChannelAvatar draws both). */
@Composable
private fun IdentityMark(identity: Identity, size: Dp) {
    com.inbox2.app.ui.components.ChannelAvatar(
        label = identity.email,
        seed = identity.key,
        isUnified = identity.provider == null,
        provider = identity.provider,
        size = size,
    )
}
