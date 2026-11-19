//! On-demand interactive operations that hit the provider directly rather than
//! the background sync loop: fetch a body, download an attachment, view source,
//! send, outbox management, conversation actions, calendar RSVP, and priority.

use serde::Serialize;
use tauri::State;

use super::SyncState;
use crate::sync::error::SyncError;

#[derive(Debug, Serialize)]
pub struct MessageSourceResponse {
    pub raw: String,
}

/// Fetch a message body on-demand (inline images resolved) + attachment list.
#[tauri::command]
pub async fn fetch_message(
    state: State<'_, SyncState>,
    account_key: String,
    message_key: String,
) -> Result<crate::sync::interactive::FetchedMessage, SyncError> {
    let provider = state.engine.interactive_provider(&account_key)?;
    provider.fetch_message(&message_key).await
}

/// The provider's own search (Gmail `q`, Graph `$search`), which reads inside
/// attachments; returns the local conversation keys it hit. Empty for IMAP/Meta.
#[tauri::command]
pub async fn provider_search(
    state: State<'_, SyncState>,
    account_key: String,
    query: String,
) -> Result<Vec<String>, SyncError> {
    let provider = state.engine.interactive_provider(&account_key)?;
    provider.search_conversations(&query).await
}

/// Download an attachment's raw bytes.
#[tauri::command]
pub async fn download_attachment(
    state: State<'_, SyncState>,
    account_key: String,
    message_key: String,
    attachment_id: String,
) -> Result<Vec<u8>, SyncError> {
    let provider = state.engine.interactive_provider(&account_key)?;
    provider.download_attachment(&message_key, &attachment_id).await
}

/// Raw RFC822 source for "view source".
#[tauri::command]
pub async fn get_message_source(
    state: State<'_, SyncState>,
    account_key: String,
    message_key: String,
) -> Result<MessageSourceResponse, SyncError> {
    let provider = state.engine.interactive_provider(&account_key)?;
    let raw = provider.get_message_source(&message_key).await?;
    Ok(MessageSourceResponse { raw })
}

/// Send a message via the account's provider. The send is persisted to a
/// durable outbox and attempted immediately; the result reports whether it
/// went out (`sent`) or is queued for retry (`pending`/`failed`).
#[tauri::command]
pub async fn send_message(
    state: State<'_, SyncState>,
    account_key: String,
    message: crate::sync::interactive::OutgoingMessage,
) -> Result<crate::sync::model::OutboxSendResult, SyncError> {
    state.engine.enqueue_send(&account_key, message).await
}

/// List outbox entries for an account (any status), newest first.
#[tauri::command]
pub async fn list_outbox(
    state: State<'_, SyncState>,
    account_key: String,
) -> Result<Vec<crate::sync::model::OutboxMessage>, SyncError> {
    state.engine.outbox().list(&account_key)
}

/// Re-queue a permanently-failed outbox entry and attempt delivery now.
#[tauri::command]
pub async fn retry_outbox_message(
    state: State<'_, SyncState>,
    account_key: String,
    key: String,
) -> Result<(), SyncError> {
    state.engine.retry_outbox_message(&account_key, &key).await
}

/// Apply an action to every message in the given conversations.
#[tauri::command]
pub async fn perform_conversation_action(
    state: State<'_, SyncState>,
    account_key: String,
    conversation_keys: Vec<String>,
    action: String,
) -> Result<(), SyncError> {
    state.engine
        .perform_conversation_action(&account_key, &conversation_keys, &action)
        .await
}

/// RSVP to an offline-synced calendar event by its local key. `response` is
/// `accepted` | `declined` | `tentative`. Writes back to the provider (Google
/// PATCH attendees / Microsoft accept|decline|tentativelyAccept), then resyncs.
#[tauri::command]
pub async fn calendar_respond_event(
    state: State<'_, SyncState>,
    account_key: String,
    event_key: String,
    response: String,
) -> Result<(), SyncError> {
    state.engine
        .respond_calendar_event_by_key(&account_key, &event_key, &response)
        .await
}

/// Create an event on an offline-synced calendar (Google/Microsoft). `draft` is
/// an `EventDraft` — set `conference: true` to have the provider mint a Google
/// Meet / Teams link, which comes back on the resync. Returns the provider id.
#[tauri::command]
pub async fn calendar_create_event(
    state: State<'_, SyncState>,
    account_key: String,
    calendar_provider_id: String,
    draft: crate::sync::calendar::EventDraft,
) -> Result<String, SyncError> {
    state.engine
        .create_calendar_event(&account_key, &calendar_provider_id, draft)
        .await
}

/// Move an offline-synced event, or its whole series, by its local key — the
/// calendar's drag/resize. Times only; guests and their RSVPs are left alone.
#[tauri::command]
pub async fn calendar_reschedule_event(
    state: State<'_, SyncState>,
    account_key: String,
    event_key: String,
    reschedule: crate::sync::calendar::Reschedule,
) -> Result<(), SyncError> {
    state.engine
        .reschedule_calendar_event_by_key(&account_key, &event_key, reschedule)
        .await
}

/// Parse an emailed meeting invite from a message's `text/calendar` attachment
/// (docs/Meeting-Invites.md). Returns the parsed invite JSON or `None`.
#[tauri::command]
pub async fn invite_for_attachment(
    state: State<'_, SyncState>,
    account_key: String,
    message_key: String,
    attachment_id: String,
) -> Result<Option<crate::sync::ics::ClientInvite>, SyncError> {
    state.engine
        .invite_from_attachment(&account_key, &message_key, &attachment_id)
        .await
}

/// RSVP to an emailed invite. `response` is `accepted` | `declined` |
/// `tentative`. Writes back to the source (calendar API when synced, else an
/// emailed METHOD:REPLY to the organizer).
#[tauri::command]
pub async fn respond_to_invite(
    state: State<'_, SyncState>,
    account_key: String,
    message_key: String,
    attachment_id: String,
    response: String,
) -> Result<(), SyncError> {
    state.engine
        .respond_invite(&account_key, &message_key, &attachment_id, &response)
        .await
}

/// Add an emailed `text/calendar` event to the account's calendar — the
/// "Add to calendar" action for ICS attachments that aren't asking for an RSVP
/// (docs/Meeting-Invites.md). Returns the local event key.
///
/// `device_timezone` is only used for a *floating* ICS time (no `Z`, no `TZID`);
/// a zoned ICS keeps its own zone so the hour can't drift.
#[tauri::command]
pub async fn add_invite_to_calendar(
    state: State<'_, SyncState>,
    account_key: String,
    message_key: String,
    attachment_id: String,
    calendar_provider_id: Option<String>,
    device_timezone: Option<String>,
) -> Result<String, SyncError> {
    state.engine
        .add_invite_to_calendar(
            &account_key,
            &message_key,
            &attachment_id,
            calendar_provider_id,
            device_timezone,
        )
        .await
}

/// The meeting the summary lane found in a message body with no ICS attached
/// (docs/Meeting-Invites.md "Detected meetings"), shaped as an invite.
#[tauri::command]
pub async fn detected_invite(
    state: State<'_, SyncState>,
    account_key: String,
    message_key: String,
) -> Result<Option<crate::sync::ics::ClientInvite>, SyncError> {
    state.engine.detected_invite(&account_key, &message_key)
}

/// "Add to calendar" for a detected meeting; its floating time is read in `device_timezone`.
#[tauri::command]
pub async fn add_detected_meeting_to_calendar(
    state: State<'_, SyncState>,
    account_key: String,
    message_key: String,
    calendar_provider_id: Option<String>,
    device_timezone: Option<String>,
) -> Result<String, SyncError> {
    state.engine
        .add_detected_meeting_to_calendar(&account_key, &message_key, calendar_provider_id, device_timezone)
        .await
}

/// Delete an offline-synced calendar event by its local key. Writes back to the
/// provider (Google `events.delete` / Microsoft `DELETE /events/{id}`), removes
/// the local row, then notifies clients.
#[tauri::command]
pub async fn calendar_delete_event(
    state: State<'_, SyncState>,
    account_key: String,
    event_key: String,
) -> Result<(), SyncError> {
    state.engine
        .delete_calendar_event_by_key(&account_key, &event_key)
        .await
}

/// Set urgent/important priority on conversations + sync the quadrant label.
#[tauri::command]
pub async fn set_priority(
    state: State<'_, SyncState>,
    account_key: String,
    conversation_keys: Vec<String>,
    urgent: bool,
    important: bool,
) -> Result<(), SyncError> {
    state.engine
        .set_conversation_priority(&account_key, &conversation_keys, urgent, important)
        .await
}

/// Clear priority on conversations + remove quadrant labels.
#[tauri::command]
pub async fn clear_priority(
    state: State<'_, SyncState>,
    account_key: String,
    conversation_keys: Vec<String>,
) -> Result<(), SyncError> {
    state.engine
        .clear_conversation_priority(&account_key, &conversation_keys)
        .await
}
