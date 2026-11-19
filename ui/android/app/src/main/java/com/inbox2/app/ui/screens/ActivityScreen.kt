package com.inbox2.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.model.ActivityEntry
import com.inbox2.app.model.Conversation
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.AvatarRing
import com.inbox2.app.ui.components.EmptyState
import com.inbox2.app.ui.components.ScreenHeader
import com.inbox2.app.ui.components.noRippleClickable
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Activity feed (iOS ActivityView): recent inbound mail with gradient avatars + an
 *  "Open" pill that jumps to the thread. Reached from the inbox header bell. */
@Composable
fun ActivityScreen(engine: EngineModel, onBack: () -> Unit, onOpenConversation: (Conversation) -> Unit) {
    val p = theme
    val dataVersion by engine.dataVersion.collectAsState()
    var entries by remember { mutableStateOf<List<ActivityEntry>>(emptyList()) }
    LaunchedEffect(dataVersion) {
        entries = withContext(Dispatchers.IO) { engine.store.recentActivity() }
    }
    Column(Modifier.fillMaxSize().background(p.bgBase)) {
        ScreenHeader("Activity", showBack = true, onBack = onBack)
        if (entries.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(bottom = 60.dp), contentAlignment = Alignment.Center) {
                EmptyState("waveform", "No recent activity", "New mail shows up here")
            }
        } else {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(Space.s4), verticalArrangement = Arrangement.spacedBy(Space.s2)) {
                items(entries.size) { i ->
                    val e = entries[i]
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.lg)).background(p.bgSurface).padding(Space.s3),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Space.s3),
                    ) {
                        AvatarRing(e.initials, 40.dp, e.seed, email = com.inbox2.app.model.MailAddress.parse(e.fromAddress).email)
                        Column(Modifier.weight(1f)) {
                            Text(e.sender, color = p.textPrimary, style = AppFont.sm, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(e.subject, color = p.textTertiary, style = AppFont.xs, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        Text(e.time, color = p.textTertiary, style = AppFont.xs2)
                        Text(
                            "Open", color = p.onAccent, style = AppFont.xs,
                            modifier = Modifier.clip(RoundedCornerShape(Radius.full)).background(p.accentViolet)
                                .noRippleClickable {
                                    engine.store.conversation(e.conversationKey)?.let(onOpenConversation)
                                }.padding(horizontal = Space.s3, vertical = Space.s1 + 2.dp),
                        )
                    }
                }
                item { Spacer(Modifier.height(40.dp)) }
            }
        }
    }
}
