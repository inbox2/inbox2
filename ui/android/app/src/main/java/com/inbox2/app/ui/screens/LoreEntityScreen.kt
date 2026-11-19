package com.inbox2.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.inbox2.app.cloud.CloudSession
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.engine.LoreBucket
import com.inbox2.app.engine.LoreEntityRef
import com.inbox2.app.engine.LoreFact
import com.inbox2.app.engine.LorePageRef
import com.inbox2.app.engine.LoreText
import com.inbox2.app.model.Conversation
import com.inbox2.app.model.MailAddress
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.AvatarRing
import com.inbox2.app.ui.components.PillButton
import com.inbox2.app.ui.components.ScreenHeader
import com.inbox2.app.ui.components.SfIcon
import com.inbox2.app.ui.components.noRippleClickable
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope

/**
 * Lore's pushed screens (docs/plans/lore.md §3–4; iOS LoreScreens.swift) — the phone's
 * versions of the desktop's org/person pages and Disk notes pages. Read-mostly: an
 * entity page lists what is open with them, who they are, what the miner learned and
 * what was done; a notes page renders its markdown (editing stays on desktop/web).
 */
@Composable
internal fun LoreEntityScreen(
    engine: EngineModel, cloud: CloudSession, ref: LoreEntityRef,
    open: List<Conversation>, done: List<Conversation>,
    onBack: () -> Unit, onOpen: (Conversation) -> Unit, onEntity: (LoreEntityRef) -> Unit,
    onDone: (List<Conversation>) -> Unit,
) {
    val p = theme
    val isOrg = ref is LoreEntityRef.Org
    fun matches(c: Conversation) = when (ref) {
        is LoreEntityRef.Org -> LoreText.orgDomain(c.email) == ref.domain
        is LoreEntityRef.Person -> c.email.lowercase() == ref.address
    }
    val name = when (ref) {
        is LoreEntityRef.Org -> LoreText.domainLabel(ref.domain)
        is LoreEntityRef.Person -> ref.name.ifEmpty { ref.address }
    }
    val subtitle = when (ref) { is LoreEntityRef.Org -> ref.domain; is LoreEntityRef.Person -> ref.address }
    val mine = open.filter(::matches)
    val openWork = mine.filter { LoreBucket.forLabel(it.triageLabel) != LoreBucket.HANDLED }
    val recent = done.filter(::matches).take(10)
    val people = loreSenders(mine + recent)
    val personDomain = (ref as? LoreEntityRef.Person)?.let { LoreText.orgDomain(it.address) }

    var facts by remember(ref) { mutableStateOf<List<LoreFact>>(emptyList()) }
    var loadingFacts by remember(ref) { mutableStateOf(true) }
    LaunchedEffect(ref) {
        val (kind, domain, address) = when (ref) {
            is LoreEntityRef.Org -> Triple("organization", ref.domain, null)
            is LoreEntityRef.Person -> Triple("person", null, ref.address)
        }
        val all = coroutineScope {
            val local = async { engine.loreFacts(kind, domain, address) }
            val remote = async { cloud.loreFacts(kind, domain, address) }
            local.await() + remote.await()
        }
        facts = all.distinctBy { "${it.kind}|${it.name}|${it.value}|${it.related}" }.sortedByDescending { it.confidence }
        loadingFacts = false
    }

    Column(Modifier.fillMaxSize().background(p.bgBase)) {
        ScreenHeader(name, showBack = true, onBack = onBack, uppercase = false)
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 120.dp)) {
            item {
                Column(Modifier.padding(horizontal = Space.s4, vertical = Space.s2), verticalArrangement = Arrangement.spacedBy(Space.s2)) {
                    if (ref is LoreEntityRef.Org) LoreLogo(ref.domain, cloud, 56.dp)
                    else AvatarRing(MailAddress.initials(name), size = 56.dp, seed = MailAddress.seed(subtitle))
                    Text(if (isOrg) "Organization · $subtitle" else "Person · $subtitle", color = p.textTertiary, style = AppFont.sm)
                    if (personDomain != null) Text("Works at ${LoreText.domainLabel(personDomain)}", color = p.accentViolet,
                        style = AppFont.sm.copy(fontWeight = FontWeight.SemiBold),
                        modifier = Modifier.noRippleClickable(onClickLabel = "Open ${LoreText.domainLabel(personDomain)}") { onEntity(LoreEntityRef.Org(personDomain)) })
                }
            }
            section("Open work", openWork.size)
            if (openWork.isEmpty()) muted("Nothing open with $name.")
            items(openWork, key = { "o:${it.id}" }) { c ->
                Row(Modifier.fillMaxWidth().padding(horizontal = Space.s4), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f).noRippleClickable(onClickLabel = "Open the email") { onOpen(c) }.padding(vertical = Space.s2)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(LoreText.clean(c.subject).ifEmpty { "(no subject)" }, color = p.textPrimary, style = AppFont.base,
                                maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                            Text(c.time, color = p.textTertiary, style = AppFont.xs2)
                        }
                        Text(c.preview, color = p.textSecondary, style = AppFont.xs, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    }
                    Spacer(Modifier.width(Space.s2))
                    PillButton("Done", compact = true, tint = Color.Transparent, contentColor = p.accentSuccess) { onDone(listOf(c)) }
                }
            }
            if (isOrg && people.isNotEmpty()) {
                section("People", people.size)
                items(people, key = { "pp:${it.address}" }) { s ->
                    Row(Modifier.fillMaxWidth().defaultMinSize(minHeight = 48.dp)
                        .noRippleClickable(onClickLabel = "Open ${s.name}") { onEntity(LoreEntityRef.Person(s.address, s.name)) }
                        .padding(horizontal = Space.s4),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s3)) {
                        AvatarRing(MailAddress.initials(s.name), size = 32.dp, seed = MailAddress.seed(s.address))
                        Column(Modifier.weight(1f)) {
                            Text(s.name, color = p.textPrimary, style = AppFont.base)
                            Text(s.address, color = p.textTertiary, style = AppFont.xs2)
                        }
                        Text("${s.count} ${if (s.count == 1) "thread" else "threads"}", color = p.textTertiary, style = AppFont.xs2)
                    }
                }
            }
            section("Learned from mail", rule = "Mined from your email")
            if (facts.isEmpty()) muted(if (loadingFacts) "Loading…" else "Nothing mined yet for this one.")
            items(facts, key = { "f:${it.kind}|${it.name}|${it.value}|${it.related}" }) { f ->
                Column(Modifier.padding(horizontal = Space.s4, vertical = Space.s1)) {
                    Text(f.line, color = p.textPrimary, style = AppFont.sm.copy(fontWeight = FontWeight.SemiBold))
                    f.quote?.let { Text("“$it”", color = p.textSecondary, style = AppFont.xs.copy(fontStyle = FontStyle.Italic)) }
                }
            }
            section("Recently done", rule = "Archived from Lore or the inbox")
            if (recent.isEmpty()) muted("Nothing archived recently.")
            items(recent, key = { "r:${it.id}" }) { c ->
                Row(Modifier.fillMaxWidth().defaultMinSize(minHeight = 44.dp).noRippleClickable(onClickLabel = "Open the email") { onOpen(c) }
                    .padding(horizontal = Space.s4),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                    Icon(SfIcon.vector("checkmark.circle.fill"), null, tint = p.accentSuccess, modifier = Modifier.size(16.dp))
                    Text(LoreText.clean(c.subject), color = p.textSecondary, style = AppFont.sm, maxLines = 1,
                        overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    Text(c.time, color = p.textTertiary, style = AppFont.xs2)
                }
            }
        }
    }
}

private fun LazyListScope.section(title: String, count: Int? = null, rule: String? = null) {
    item(key = "s:$title") {
        val p = theme
        Row(Modifier.fillMaxWidth().padding(horizontal = Space.s4).padding(top = Space.s4, bottom = Space.s1),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
            Text(title, color = p.textSecondary, style = AppFont.label(13))
            count?.let { Text("$it", color = p.textTertiary, style = AppFont.xs2) }
            rule?.let { Text(it, color = p.textTertiary, style = AppFont.xs2) }
        }
    }
}

private fun LazyListScope.muted(text: String) {
    item { Text(text, color = theme.textTertiary, style = AppFont.sm, modifier = Modifier.padding(horizontal = Space.s4, vertical = Space.s1)) }
}

// ── Notes page (read-only) ──

@Composable
internal fun LorePageScreen(cloud: CloudSession, orgId: String, page: LorePageRef, onBack: () -> Unit) {
    val p = theme
    var markdown by remember(page.id) { mutableStateOf<String?>(null) }
    var error by remember(page.id) { mutableStateOf<String?>(null) }
    var attempt by remember { mutableStateOf(0) }
    LaunchedEffect(page.id, attempt) {
        error = null
        runCatching { cloud.lorePageMarkdown(orgId, page.id) }
            .onSuccess { markdown = it }.onFailure { error = it.message ?: "unknown error" }
    }
    Column(Modifier.fillMaxSize().background(p.bgBase)) {
        ScreenHeader(page.name, showBack = true, onBack = onBack, uppercase = false)
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = Space.s4).padding(bottom = 120.dp),
            verticalArrangement = Arrangement.spacedBy(Space.s2)) {
            Text("Edit this page in Lore on your computer.", color = p.textTertiary, style = AppFont.xs)
            val md = markdown
            when {
                error != null -> {
                    Text("Can't open this page. $error", color = p.accentDanger, style = AppFont.sm)
                    PillButton("Try again", compact = true, tint = Color.Transparent, contentColor = p.accentViolet) { attempt++ }
                }
                md == null -> Box(Modifier.fillMaxWidth().padding(Space.s6), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = p.accentViolet, modifier = Modifier.size(24.dp))
                }
                md.isBlank() -> Text("Nothing here yet. Add notes on your computer.", color = p.textTertiary, style = AppFont.sm)
                else -> md.lines().forEach { MarkdownLine(it) }
            }
        }
    }
}

/** One markdown line: headings, to-dos, bullets, quotes, else a paragraph with inline marks.
 *  ponytail: line-by-line, no tables/code fences; a real renderer when pages need them on the phone. */
@Composable
private fun MarkdownLine(raw: String) {
    val p = theme
    val line = raw.trim()
    fun strip(vararg prefixes: String) = prefixes.firstOrNull { line.startsWith(it) }?.let { line.removePrefix(it) }
    when {
        line.isEmpty() -> Spacer(Modifier.height(Space.s1))
        line.startsWith("#") -> {
            val level = line.takeWhile { it == '#' }.length
            Text(inline(line.drop(level).trim()), color = p.textPrimary,
                style = if (level == 1) AppFont.title2 else AppFont.lg, modifier = Modifier.padding(top = Space.s2))
        }
        strip("- [ ] ", "* [ ] ") != null -> Bullet("circle", p.textTertiary, strip("- [ ] ", "* [ ] ")!!)
        strip("- [x] ", "- [X] ", "* [x] ") != null -> Bullet("checkmark.circle.fill", p.accentSuccess, strip("- [x] ", "- [X] ", "* [x] ")!!, done = true)
        strip("- ", "* ", "+ ") != null -> Bullet("circle.fill", p.textTertiary, strip("- ", "* ", "+ ")!!, small = true)
        strip("> ") != null -> Row {
            Box(Modifier.width(2.dp).height(20.dp).background(p.borderStrong))
            Spacer(Modifier.width(Space.s3))
            Text(inline(strip("> ")!!), color = p.textSecondary, style = AppFont.sm.copy(fontStyle = FontStyle.Italic))
        }
        else -> Text(inline(line), color = p.textPrimary, style = AppFont.base)
    }
}

@Composable
private fun Bullet(icon: String, tint: Color, text: String, done: Boolean = false, small: Boolean = false) {
    val p = theme
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
        Icon(SfIcon.vector(icon), null, tint = tint, modifier = Modifier.size(if (small) 5.dp else 14.dp))
        Text(inline(text), color = if (done) p.textTertiary else p.textPrimary,
            style = AppFont.base.copy(textDecoration = if (done) TextDecoration.LineThrough else null))
    }
}

/** **bold**, *italic* / _italic_, `code` and [text](url) (shown as text) — enough for notes. */
private fun inline(s: String): AnnotatedString = buildAnnotatedString {
    val re = Regex("""\*\*(.+?)\*\*|\*(.+?)\*|_(.+?)_|`(.+?)`|\[(.+?)]\((.+?)\)""")
    var at = 0
    for (m in re.findAll(s)) {
        append(s.substring(at, m.range.first))
        val g = m.groupValues
        when {
            g[1].isNotEmpty() -> withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(g[1]) }
            g[2].isNotEmpty() -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append(g[2]) }
            g[3].isNotEmpty() -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append(g[3]) }
            g[4].isNotEmpty() -> withStyle(SpanStyle(fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)) { append(g[4]) }
            else -> withStyle(SpanStyle(textDecoration = TextDecoration.Underline)) { append(g[5]) }
        }
        at = m.range.last + 1
    }
    append(s.substring(at))
}

// ── Organization logos (docs/plans/lore.md §4b; iOS LoreLogo) ──

/** Brand icons by domain, fetched once per session through the image proxy (only the
 *  domain and the icon URL leave the device). A failed lookup caches as null. */
private object LoreLogos {
    private val cache = HashMap<String, kotlinx.coroutines.Deferred<androidx.compose.ui.graphics.ImageBitmap?>>()
    private val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.IO)

    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    fun load(domain: String, cloud: CloudSession, bearer: String?) = synchronized(cache) {
        // Only hits stay cached: a finished miss is looked up again next time.
        cache[domain]?.let { if (it.isCompleted && it.getCompleted() == null) cache.remove(domain) }
        cache.getOrPut(domain) {
            scope.async {
                val remote = cloud.brandIconUrl(domain) ?: return@async null
                val bytes = com.inbox2.app.cloud.ImageProxy.fetch(remote, bearer, timeoutMs = 10_000)?.second ?: return@async null
                // SVG and other undecodable icons fall back to initials.
                android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
            }
        }
    }
}

/** An organization's logo (its site icon), initials until — or unless — it loads. */
@Composable
internal fun LoreLogo(domain: String, cloud: CloudSession, size: androidx.compose.ui.unit.Dp) {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    var bitmap by remember(domain) { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }
    LaunchedEffect(domain) {
        bitmap = LoreLogos.load(domain, cloud, com.inbox2.app.cloud.PrivacyStore(ctx).bearer()).await()
    }
    val b = bitmap
    if (b != null) androidx.compose.foundation.Image(b, contentDescription = null,
        modifier = Modifier.size(size).clip(androidx.compose.foundation.shape.RoundedCornerShape(size / 4)))
    else AvatarRing(MailAddress.initials(LoreText.domainLabel(domain)), size = size, seed = MailAddress.seed(domain))
}
