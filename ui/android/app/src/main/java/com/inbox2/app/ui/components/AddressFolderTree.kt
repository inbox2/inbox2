package com.inbox2.app.ui.components

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import android.content.Context
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.inbox2.app.cloud.CloudAddressFolder
import com.inbox2.app.cloud.CloudAddressFolder.Companion.KIND_INBOX
import com.inbox2.app.cloud.CloudAddressFolder.Companion.KIND_OTHER
import com.inbox2.app.cloud.CloudAddressFolder.Companion.KIND_OWN
import com.inbox2.app.cloud.CloudAddressFolder.Companion.KIND_SHARED
import com.inbox2.app.cloud.CloudAddressFolder.Companion.KIND_TAG
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme

/** Bell / Show in Inbox change for one folder: null = leave as is. */
typealias FolderPrefChange = (folder: CloudAddressFolder, inbox: Boolean?, notify: Boolean?) -> Unit

/**
 * The MX domain's address folders under Inbox (web AddressFolderTree): "Yours" (your
 * addresses, each +tag indented under it) and "Shared", each with its total unread,
 * then "Other". Tap selects the folder; the bell toggles notifications; long-press
 * opens Show in Inbox (shared and tag folders) + Notify me. Other has no prefs.
 */
@Composable
fun AddressFolderTree(folders: List<CloudAddressFolder>, selection: String?, onSelect: (String) -> Unit, onSetPref: FolderPrefChange) {
    val own = folders.filter { it.kind == KIND_OWN }
    val yours = own.flatMap { o -> listOf(o) + folders.filter { it.kind == KIND_TAG && it.parent == o.key } }
    val shared = folders.filter { it.kind == KIND_SHARED }
    val other = folders.firstOrNull { it.kind == KIND_OTHER }
    // Collapsed groups, kept across launches like the web's. Default: both closed.
    val prefs = LocalContext.current.getSharedPreferences(TREE_PREFS, Context.MODE_PRIVATE)
    var collapsed by remember { mutableStateOf(setOf(GROUP_YOURS, GROUP_SHARED).filter { prefs.getBoolean(it, true) }.toSet()) }
    val toggle = { group: String ->
        collapsed = if (group in collapsed) collapsed - group else collapsed + group
        prefs.edit().putBoolean(group, group in collapsed).apply()
    }
    @Composable
    fun group(id: String, title: String, list: List<CloudAddressFolder>) {
        if (list.isEmpty()) return
        val open = id !in collapsed
        GroupHead(title, list.sumOf { it.unread }, open) { toggle(id) }
        // A collapsed group still shows the open folder, so the selection never hides.
        list.filter { open || it.key == selection }.forEach {
            AddressFolderRow(it, it.key == selection, indent = it.kind == KIND_TAG, onSelect = { onSelect(it.key) }, onSetPref = onSetPref)
        }
    }
    group(GROUP_YOURS, "Yours", yours)
    group(GROUP_SHARED, "Shared", shared)
    other?.let { AddressFolderRow(it, it.key == selection, onSelect = { onSelect(it.key) }, onSetPref = onSetPref) }
}

private const val TREE_PREFS = "inbox2_address_tree"
private const val GROUP_YOURS = "collapsed_yours"
private const val GROUP_SHARED = "collapsed_shared"

@Composable
private fun GroupHead(title: String, unread: Int, open: Boolean, onToggle: () -> Unit) {
    val p = theme
    Row(Modifier.fillMaxWidth()
            .noRippleClickable(onClickLabel = if (open) "Collapse $title" else "Expand $title") { onToggle() }
            .padding(start = Space.s5 + 20.dp, end = Space.s5, top = Space.s2, bottom = Space.s1),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(SfIcon.vector(if (open) "chevron.down" else "chevron.right"), null, tint = p.textTertiary,
            modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(Space.s1))
        Text(title.uppercase(), color = p.textTertiary, style = AppFont.ui(12, FontWeight.SemiBold), modifier = Modifier.weight(1f))
        if (unread > 0) Text("$unread", color = p.textTertiary, style = AppFont.ui(12, FontWeight.SemiBold))
    }
}

/** One folder row. Also draws the Inbox row when the tree is loaded (its bell and count). */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun AddressFolderRow(
    folder: CloudAddressFolder,
    active: Boolean,
    indent: Boolean = false,
    onSelect: () -> Unit,
    onSetPref: FolderPrefChange,
) {
    val p = theme
    val hasPrefs = folder.kind != KIND_OTHER
    var menu by remember { mutableStateOf(false) }
    val isInbox = folder.kind == KIND_INBOX
    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .then(if (active) Modifier.background(p.accentViolet.copy(alpha = 0.12f)) else Modifier)
                .combinedClickable(interactionSource = remember { MutableInteractionSource() }, indication = null,
                    onLongClick = if (hasPrefs) ({ menu = true }) else null, onClick = onSelect)
                .padding(start = Space.s5 + if (isInbox) 0.dp else if (indent) 40.dp else 24.dp, end = Space.s5)
                .padding(vertical = if (isInbox) Space.s3 + 2.dp else Space.s2 + 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(SfIcon.vector(if (isInbox) "tray" else if (folder.kind == KIND_OTHER) "tray.2.fill" else "at"), null,
                tint = if (active) p.accentViolet else p.textSecondary,
                modifier = Modifier.width(28.dp).size(if (isInbox) 20.dp else 17.dp))
            Spacer(Modifier.width(Space.s3))
            // The label takes the free width, so counts and bells line up on the right.
            Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
                Text(folder.treeLabel, color = if (active) p.textPrimary else p.textSecondary, maxLines = 1,
                    style = AppFont.ui(if (isInbox) 17 else 15, if (active) FontWeight.SemiBold else FontWeight.Normal),
                    modifier = Modifier.weight(1f, fill = false))
                // Like iOS: plain "Read only" on an address you can't reply as; no icon.
                if ((folder.kind == KIND_OWN || folder.kind == KIND_SHARED) && !folder.canReply) {
                    Spacer(Modifier.width(Space.s2))
                    Text("Read only", color = p.textTertiary, maxLines = 1, style = AppFont.ui(11, FontWeight.SemiBold))
                }
            }
            if (folder.unread > 0) Text("${folder.unread}", color = if (active) p.accentViolet else p.textTertiary,
                style = AppFont.ui(13, FontWeight.SemiBold), modifier = Modifier.padding(end = Space.s3))
            if (hasPrefs) Box(
                Modifier.size(28.dp).clip(CircleShape).noRippleClickable(
                    onClickLabel = if (folder.notify) "Turn notifications off" else "Turn notifications on",
                ) { onSetPref(folder, null, !folder.notify) },
                contentAlignment = Alignment.Center,
            ) {
                Icon(SfIcon.vector(if (folder.notify) "bell" else "bell.slash"),
                    if (folder.notify) "Notifications on" else "Notifications off",
                    tint = if (folder.notify) p.accentViolet else p.textTertiary, modifier = Modifier.size(15.dp))
            }
        }
        GlassDropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (folder.hasInboxToggle) PrefItem("Show in Inbox", folder.inInbox) { menu = false; onSetPref(folder, !folder.inInbox, null) }
            PrefItem("Notify me", folder.notify) { menu = false; onSetPref(folder, null, !folder.notify) }
        }
    }
}

@Composable
private fun PrefItem(label: String, on: Boolean, onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text(label, color = theme.textPrimary, style = AppFont.sm) },
        leadingIcon = {
            // An empty slot when off keeps the labels aligned.
            if (on) Icon(SfIcon.vector("checkmark"), null, tint = theme.accentViolet, modifier = Modifier.size(18.dp))
            else Spacer(Modifier.size(18.dp))
        },
        onClick = onClick,
    )
}

/** Top of a shared folder's list when you can read the address but not reply as it.
 *  Reply-as is an admin setting; there is no request flow. */
@Composable
fun ReadOnlyFolderNotice(folder: CloudAddressFolder?, modifier: Modifier = Modifier) {
    if (folder?.readOnly != true) return
    val p = theme
    Row(modifier.fillMaxWidth().padding(horizontal = Space.s4, vertical = Space.s2), verticalAlignment = Alignment.CenterVertically) {
        Icon(SfIcon.vector("eye"), null, tint = p.accentAmber, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(Space.s2))
        Text("You can read ${folder.label} but not reply as it. An admin gives reply-as in the console.",
            color = p.textSecondary, style = AppFont.xs)
    }
}
