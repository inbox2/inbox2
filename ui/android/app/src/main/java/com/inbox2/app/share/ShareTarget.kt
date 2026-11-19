package com.inbox2.app.share

import android.net.Uri
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * A pending ACTION_SEND / ACTION_SEND_MULTIPLE payload, handed from MainActivity to the
 * composition. Mirrors [com.inbox2.app.notify.NotificationHelper.tappedConversation]: a
 * flow (not a direct call) so a cold-launch share survives until RootTabs exists to read
 * it. RootTabs reads the content-URI bytes off the main thread and opens compose with the
 * files pre-loaded as attachments.
 */
data class PendingShare(
    val subject: String?,
    val text: String?,
    val uris: List<Uri>,
)

object ShareTarget {
    val pending = MutableStateFlow<PendingShare?>(null)
}
