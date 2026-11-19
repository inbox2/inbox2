package com.inbox2.app.ui.components

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.material.icons.automirrored.filled.ReplyAll
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material.icons.automirrored.outlined.Logout
import androidx.compose.material.icons.automirrored.outlined.Notes
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * Maps the SF-Symbol names carried by the shared models (MailFolder, Quadrant,
 * ConversationAction) to Material icons, so the Android UI keeps the same glyph
 * meaning as iOS without re-deriving icon choices at every call site. Falls back to a
 * neutral circle for anything unmapped.
 */
object SfIcon {
    fun vector(name: String): ImageVector = when (name) {
        // mailboxes / folders
        "tray", "tray.full" -> Icons.Outlined.Inbox
        "paperplane" -> Icons.AutoMirrored.Filled.Send
        "paperplane.fill" -> Icons.AutoMirrored.Filled.Send
        "doc" -> Icons.Outlined.Description
        "tray.and.arrow.up" -> Icons.Outlined.Outbox
        "tray.and.arrow.down" -> Icons.Outlined.MoveToInbox
        "archivebox" -> Icons.Outlined.Archive
        "trash" -> Icons.Outlined.Delete
        // triage / quadrants
        "flame.fill" -> Icons.Filled.LocalFireDepartment
        "calendar.badge.clock" -> Icons.Outlined.EditCalendar
        "person.badge.plus" -> Icons.Outlined.PersonAddAlt
        "clock" -> Icons.Outlined.Schedule
        "star" -> Icons.Outlined.StarOutline
        "exclamationmark.circle" -> Icons.Outlined.ErrorOutline
        "exclamationmark.triangle" -> Icons.Outlined.WarningAmber
        "calendar" -> Icons.Outlined.CalendarMonth
        "person.2" -> Icons.Outlined.Group
        // actions
        "envelope.open" -> Icons.Outlined.MarkEmailRead
        "envelope.badge" -> Icons.Outlined.MarkEmailUnread
        "envelope" -> Icons.Outlined.Email
        "flag" -> Icons.Outlined.Flag
        "flag.slash" -> Icons.Outlined.OutlinedFlag
        "exclamationmark.octagon" -> Icons.Outlined.Report
        "xmark.circle" -> Icons.Outlined.Cancel
        "xmark" -> Icons.Filled.Close
        "chevron.left" -> Icons.AutoMirrored.Filled.ArrowBack
        "chevron.right" -> Icons.Filled.ChevronRight
        "chevron.down" -> Icons.Filled.ExpandMore
        "line.3.horizontal" -> Icons.Filled.Menu
        "magnifyingglass" -> Icons.Filled.Search
        "arrow.uturn.backward" -> Icons.AutoMirrored.Filled.Reply
        "arrowshape.turn.up.left" -> Icons.AutoMirrored.Filled.Reply
        "arrowshape.turn.up.left.2" -> Icons.AutoMirrored.Filled.ReplyAll
        "arrowshape.turn.up.right" -> Icons.AutoMirrored.Filled.Send
        "ellipsis" -> Icons.Filled.MoreHoriz
        "square.and.pencil" -> Icons.Outlined.Edit
        "doc.on.doc" -> Icons.Outlined.ContentCopy
        "plus" -> Icons.Filled.Add
        "gearshape" -> Icons.Outlined.Settings
        "waveform" -> Icons.Outlined.GraphicEq
        "checklist" -> Icons.Outlined.Checklist
        "speaker.wave.2" -> Icons.AutoMirrored.Filled.VolumeUp
        "paperclip" -> Icons.Outlined.AttachFile
        "photo" -> Icons.Outlined.Image
        "doc.richtext" -> Icons.Outlined.PictureAsPdf
        "video" -> Icons.Outlined.Videocam
        "music.note" -> Icons.Outlined.MusicNote
        "doc.zipper" -> Icons.Outlined.FolderZip
        "doc.text" -> Icons.Outlined.Description
        "rectangle.on.rectangle" -> Icons.Outlined.Slideshow
        "calendar.badge.plus" -> Icons.Outlined.EditCalendar
        "scope" -> Icons.Outlined.CenterFocusStrong
        "nosign" -> Icons.Outlined.Block
        "bell.badge" -> Icons.Outlined.NotificationsActive
        "bell.slash" -> Icons.Outlined.NotificationsOff
        "tablecells" -> Icons.Outlined.GridOn
        "person.crop.circle" -> Icons.Outlined.AccountCircle
        "arrow.clockwise" -> Icons.Outlined.Refresh
        "lock.fill" -> Icons.Outlined.Lock
        "lock.open" -> Icons.Outlined.LockOpen
        "safari" -> Icons.Outlined.OpenInBrowser
        "square.and.arrow.up" -> Icons.Outlined.Share
        "externaldrive.badge.exclamationmark" -> Icons.Outlined.SdCardAlert
        "bell" -> Icons.Outlined.Notifications
        "checkmark" -> Icons.Filled.Check
        "checkmark.circle" -> Icons.Outlined.CheckCircle
        "checkmark.circle.fill" -> Icons.Filled.CheckCircle
        "circle" -> Icons.Outlined.RadioButtonUnchecked
        // AI / sentiment / intent
        "sparkles" -> Icons.Outlined.AutoAwesome
        "brain" -> Icons.Outlined.Psychology
        "cpu" -> Icons.Outlined.Memory
        "cloud" -> Icons.Outlined.Cloud
        "text.alignleft", "text.justify.left", "text.justify" -> Icons.AutoMirrored.Outlined.Notes
        "doc.plaintext" -> Icons.Outlined.Description
        "face.smiling" -> Icons.Outlined.SentimentSatisfied
        "face.dashed" -> Icons.Outlined.SentimentDissatisfied
        "questionmark.circle" -> Icons.AutoMirrored.Outlined.HelpOutline
        "exclamationmark.bubble" -> Icons.Outlined.Forum
        "info.circle" -> Icons.Outlined.Info
        "person.wave.2" -> Icons.Outlined.WavingHand
        // settings / dev / misc
        "key.fill" -> Icons.Outlined.Key
        "at" -> Icons.Outlined.AlternateEmail
        "globe" -> Icons.Outlined.Public
        "ladybug" -> Icons.Outlined.BugReport
        "curlybraces" -> Icons.Outlined.DataObject
        "ellipsis.circle" -> Icons.Outlined.MoreHoriz
        "note.text" -> Icons.AutoMirrored.Outlined.Notes
        "pencil" -> Icons.Outlined.Edit
        "tag" -> Icons.Outlined.Sell
        "mappin.and.ellipse" -> Icons.Outlined.LocationOn
        "mic.fill" -> Icons.Filled.Mic
        "sunrise" -> Icons.Outlined.WbSunny
        "plus.circle" -> Icons.Outlined.AddCircleOutline
        "person.crop.circle.badge.plus" -> Icons.Outlined.PersonAddAlt
        "rectangle.portrait.and.arrow.right" -> Icons.AutoMirrored.Outlined.Logout
        "arrow.down.circle" -> Icons.Outlined.Download
        "arrow.triangle.2.circlepath" -> Icons.Outlined.Sync
        "chevron.up.chevron.down" -> Icons.Outlined.UnfoldMore
        "chevron.up" -> Icons.Filled.ExpandLess
        "xmark.circle.fill" -> Icons.Filled.Cancel
        "xmark.bin" -> Icons.Outlined.Delete
        "clock.badge" -> Icons.Outlined.Schedule
        "gamecontroller.fill" -> Icons.Outlined.SportsEsports
        "burst.fill" -> Icons.Outlined.AutoAwesome
        "car", "car.fill" -> Icons.Filled.DirectionsCar
        "questionmark.circle", "questionmark.circle.fill" -> Icons.AutoMirrored.Outlined.HelpOutline
        "building.2" -> Icons.Outlined.Business   // Lore org links
        "person" -> Icons.Outlined.Person
        else -> Icons.Outlined.Circle
    }
}
