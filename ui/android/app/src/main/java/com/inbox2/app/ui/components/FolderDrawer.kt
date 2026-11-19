package com.inbox2.app.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.inbox2.app.model.MailFolder
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.scrim
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.colorHex
import com.inbox2.app.theme.theme

/**
 * Slide-in folder/mailbox drawer (iOS FolderDrawer). Mailboxes + a TRIAGE section whose
 * rows carry the desktop Eisenhower quadrant tints. Tap the dim scrim or close to dismiss.
 */
@Composable
fun FolderDrawer(visible: Boolean, selection: MailFolder, channelLabel: String, onSelect: (MailFolder) -> Unit, onDismiss: () -> Unit, provider: String? = null) {
    val p = theme
    // Meta accounts (Instagram/Messenger/WhatsApp) show channel/kind sub-views
    // instead of mailboxes + triage. See docs/Cloud-Push.md (Meta).
    val metaFolders = MailFolder.meta(provider)
    AnimatedVisibility(visible, enter = fadeIn(), exit = fadeOut()) {
        Box(
            Modifier
                .fillMaxSize()
                .background(scrim(0.35f))
                .noRippleClickable { onDismiss() }
        )
    }
    AnimatedVisibility(
        visible,
        enter = slideInHorizontally { -it },
        exit = slideOutHorizontally { -it },
    ) {
        Column(
            Modifier
                .fillMaxHeight()
                .fillMaxWidth(0.82f)
                .background(p.bgPanel.copy(alpha = 0.98f))
                .verticalScroll(rememberScrollState())
                .padding(top = Space.s8),
        ) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = Space.s5, vertical = Space.s5),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Mailboxes", color = p.textPrimary, style = AppFont.display)
                    if (channelLabel.isNotEmpty()) Text(channelLabel, color = p.textTertiary, style = AppFont.sm)
                }
                Box(
                    Modifier.size(38.dp).clip(CircleShape).background(p.bgElevated.copy(alpha = 0.7f))
                        .noRippleClickable { onDismiss() },
                    contentAlignment = Alignment.Center,
                ) { Icon(SfIcon.vector("xmark"), "Close", tint = p.textSecondary, modifier = Modifier.size(16.dp)) }
            }

            if (metaFolders != null) {
                metaFolders.forEach { FolderRow(it, selection, onSelect) }
            } else {
                MailFolder.mailboxes.forEach { FolderRow(it, selection, onSelect) }

                Text(
                    "TRIAGE", color = p.textTertiary, style = AppFont.ui(12, FontWeight.SemiBold),
                    modifier = Modifier.padding(horizontal = Space.s5, vertical = Space.s2).padding(top = Space.s3),
                )
                MailFolder.triage.forEach { FolderRow(it, selection, onSelect) }
            }
            Spacer(Modifier.size(Space.s8))
        }
    }
}

@Composable
private fun FolderRow(folder: MailFolder, selection: MailFolder, onSelect: (MailFolder) -> Unit) {
    val p = theme
    val active = folder == selection
    val tint = folder.tintHex?.let { colorHex(it) }
    val accent = tint ?: p.accentViolet
    Row(
        Modifier
            .fillMaxWidth()
            .then(if (active) Modifier.background(accent.copy(alpha = 0.12f)) else Modifier)
            .noRippleClickable { onSelect(folder) }
            .padding(horizontal = Space.s5, vertical = Space.s3 + 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            SfIcon.vector(folder.sfIcon), folder.title,
            tint = tint ?: (if (active) p.accentViolet else p.textSecondary),
            modifier = Modifier.width(28.dp).size(20.dp),
        )
        Spacer(Modifier.width(Space.s3))
        Text(
            folder.title, color = if (active) p.textPrimary else p.textSecondary,
            style = AppFont.ui(17, if (active) FontWeight.SemiBold else FontWeight.Normal),
        )
        Spacer(Modifier.weight(1f))
        if (active) Box(Modifier.size(7.dp).clip(CircleShape).background(accent))
    }
}
