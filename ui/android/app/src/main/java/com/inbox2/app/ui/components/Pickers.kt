package com.inbox2.app.ui.components

import com.inbox2.app.model.DateFmt
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.dp
import com.inbox2.app.cloud.CloudZone
import com.inbox2.app.cloud.CloudZoneCategory
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.model.CalendarEvent
import com.inbox2.app.model.DayHeader
import com.inbox2.app.model.EVENT_URL_RE
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Calendar
import java.util.Date
import java.util.Locale

// Date / time picker dialogs (moved out of CalendarSheets.kt, 2026-10-18). Shared by the
// event + zone sheets and compose schedule-send.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun DatePick(initialMs: Long, onResult: (Long?) -> Unit) {
    val state = rememberDatePickerState(initialSelectedDateMillis = initialMs)
    DatePickerDialog(
        onDismissRequest = { onResult(null) },
        confirmButton = { PillTextButton("OK") { onResult(state.selectedDateMillis) } },
        dismissButton = { PillTextButton("Cancel") { onResult(null) } },
    ) { DatePicker(state = state) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TimePick(initialMs: Long, onResult: (Long?) -> Unit) {
    val c = Calendar.getInstance().apply { timeInMillis = initialMs }
    val state = rememberTimePickerState(initialHour = c.get(Calendar.HOUR_OF_DAY), initialMinute = c.get(Calendar.MINUTE), is24Hour = true)
    AlertDialog(
        onDismissRequest = { onResult(null) },
        confirmButton = {
            PillTextButton("OK") {
                val cc = Calendar.getInstance().apply {
                    timeInMillis = initialMs; set(Calendar.HOUR_OF_DAY, state.hour); set(Calendar.MINUTE, state.minute); set(Calendar.SECOND, 0)
                }
                onResult(cc.timeInMillis)
            }
        },
        dismissButton = { PillTextButton("Cancel") { onResult(null) } },
        text = { TimePicker(state = state) },
    )
}
