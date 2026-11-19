use serde_json::json;

use crate::mcp::protocol::ToolDefinition;

/// All available MCP tool definitions.
pub fn tool_definitions() -> Vec<ToolDefinition> {
    vec![
        // ── Read-only ──────────────────────────────────────────────
        ToolDefinition {
            name: "search_messages".into(),
            description: "Keyword (full-text) search over email messages: subject, people, body and attachment filenames. Covers connected mailboxes and inbox2-hosted mail. Every word must match (write OR between words for either); when none match all words, results matching any word come back marked matched: any_word. Best match first (score is per mailbox source, so results interleave by rank rather than by score), or newest first with sort: date; snippets show the text around the match.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "query": { "type": "string", "description": "Search query text" },
                    "limit": { "type": "integer", "description": "Max results (default 20)", "default": 20 },
                    "account_key": { "type": "string", "description": "Scope to a specific account" },
                    "after": { "type": "string", "description": "Only mail on or after this ISO 8601 date, e.g. 2026-07-01" },
                    "before": { "type": "string", "description": "Only mail before this ISO 8601 date (exclusive), e.g. 2026-10-01" },
                    "sort": { "type": "string", "enum": ["relevance", "date"], "description": "relevance (default) or date (newest first)" },
                    "include_spam_trash": { "type": "boolean", "description": "Also search inbox2-hosted spam and trash (default false)" }
                },
                "required": ["query"]
            }),
        },
        ToolDefinition {
            name: "search_similar".into(),
            description: "Find messages semantically similar to a given message".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "message_key": { "type": "string", "description": "Key of the source message" },
                    "limit": { "type": "integer", "default": 10 }
                },
                "required": ["message_key"]
            }),
        },
        ToolDefinition {
            name: "read_message".into(),
            description: "Get the full content of a single email message. HTML-only mail comes back as text in body_plain.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "message_key": { "type": "string" },
                    "include_html": { "type": "boolean", "description": "Also return the raw HTML body (default false)" }
                },
                "required": ["message_key"]
            }),
        },
        ToolDefinition {
            name: "read_conversation".into(),
            description: "Get all messages in an email thread/conversation. Replies come without the quoted history they repeat.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "conversation_key": { "type": "string" },
                    "include_quoted": { "type": "boolean", "description": "Keep each reply's quoted history (default false)" }
                },
                "required": ["conversation_key"]
            }),
        },
        ToolDefinition {
            name: "list_conversations".into(),
            description: "List conversations with optional filters".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "status": { "type": "string", "enum": ["open", "archived", "trash", "spam"] },
                    "account_key": { "type": "string" },
                    "limit": { "type": "integer", "default": 50 },
                    "offset": { "type": "integer", "default": 0 }
                }
            }),
        },
        ToolDefinition {
            name: "list_accounts".into(),
            description: "List all connected email accounts. An inbox2-hosted org lists your own addresses (email_addresses) and the domains whose mail it holds (domains).".into(),
            input_schema: json!({ "type": "object", "properties": {} }),
        },
        ToolDefinition {
            name: "list_folders".into(),
            description: "List folders/labels for an account; for an inbox2-hosted org, its status folders, Spaces and tags".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "account_key": { "type": "string" }
                },
                "required": ["account_key"]
            }),
        },
        ToolDefinition {
            name: "get_calendar_events".into(),
            description: "List calendar events within a date range, across all calendars. Ranges inside the synced window (180 days back to a year ahead) read the local mirror; anything older or further out is fetched live from Google/Microsoft. Always returns {source: local|provider, events (each with its calendar name), failed_calendars}; an event matches when it starts before end and ends after start.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "start": { "type": "string", "description": "YYYY-MM-DD or RFC 3339 start" },
                    "end": { "type": "string", "description": "YYYY-MM-DD or RFC 3339 end" },
                    "account_key": { "type": "string" }
                },
                "required": ["start", "end"]
            }),
        },
        ToolDefinition {
            name: "get_contact_context".into(),
            description: "Get all conversations and interaction history for an email address".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "email_address": { "type": "string" }
                },
                "required": ["email_address"]
            }),
        },
        ToolDefinition {
            name: "list_attachments".into(),
            description: "List a message's attachments (id, filename, mime type, size). May fetch from the mail provider.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "message_key": { "type": "string" }
                },
                "required": ["message_key"]
            }),
        },
        ToolDefinition {
            name: "get_attachment".into(),
            description: "Download one attachment (up to 10 MB). Images come back as images, text as text, other files (PDF, Office, zip) as a base64 embedded resource.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "message_key": { "type": "string" },
                    "attachment_id": { "type": "string", "description": "From list_attachments" }
                },
                "required": ["message_key", "attachment_id"]
            }),
        },
        // ── Write ──────────────────────────────────────────────────
        ToolDefinition {
            name: "compose_draft".into(),
            description: "Save a draft (unsent) in the account's Drafts. Queued and retried like a send; returns a draft_key — pass it again to replace that draft with a newer version (only the latest is kept). reply_to_message (a message key) makes it a threaded reply.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "account_key": { "type": "string" },
                    "to": { "type": "string", "description": "Comma-separated addresses" },
                    "from": { "type": "string", "description": "inbox2-hosted orgs only: sending address (default: the one the thread was sent to, else your primary)" },
                    "cc": { "type": "string", "description": "Comma-separated addresses" },
                    "bcc": { "type": "string", "description": "Comma-separated addresses" },
                    "subject": { "type": "string" },
                    "body": { "type": "string", "description": "Plain text; an HTML version is generated" },
                    "body_html": { "type": "string" },
                    "reply_to_message": { "type": "string", "description": "Message key to reply to" },
                    "draft_key": { "type": "string", "description": "From an earlier compose_draft: replace that draft" }
                },
                "required": ["account_key", "to", "subject", "body"]
            }),
        },
        ToolDefinition {
            name: "add_tag".into(),
            description: "Tag conversations: a Gmail label (must already exist), an Outlook category, an IMAP folder of that name, or an inbox2 org tag (see list_folders)".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "account_key": { "type": "string" },
                    "conversation_keys": { "type": "array", "items": { "type": "string" } },
                    "tag": { "type": "string" }
                },
                "required": ["account_key", "conversation_keys", "tag"]
            }),
        },
        ToolDefinition {
            name: "remove_tag".into(),
            description: "Remove a tag (Gmail label / Outlook category / IMAP folder copy) from conversations".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "account_key": { "type": "string" },
                    "conversation_keys": { "type": "array", "items": { "type": "string" } },
                    "tag": { "type": "string" }
                },
                "required": ["account_key", "conversation_keys", "tag"]
            }),
        },
        ToolDefinition {
            name: "create_conversation".into(),
            description: "Send a new email that starts its own thread (requires approval unless auto-approve is on)".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "account_key": { "type": "string" },
                    "to": { "type": "string", "description": "Comma-separated addresses" },
                    "from": { "type": "string", "description": "inbox2-hosted orgs only: sending address (default: the one the thread was sent to, else your primary)" },
                    "cc": { "type": "string", "description": "Comma-separated addresses" },
                    "bcc": { "type": "string", "description": "Comma-separated addresses" },
                    "subject": { "type": "string" },
                    "body": { "type": "string", "description": "Plain text; an HTML version is generated" },
                    "body_html": { "type": "string" }
                },
                "required": ["account_key", "to", "subject"]
            }),
        },
        ToolDefinition {
            name: "move_to_folder".into(),
            description: "Move conversations to a folder: its key from list_folders, its role (inbox/archive/trash/spam) or its name. On an inbox2-hosted org the folders are the statuses and its Spaces.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "account_key": { "type": "string" },
                    "conversation_keys": { "type": "array", "items": { "type": "string" } },
                    "folder": { "type": "string", "description": "Target folder key or well-known role" }
                },
                "required": ["account_key", "conversation_keys", "folder"]
            }),
        },
        ToolDefinition {
            name: "mark_read".into(),
            description: "Mark messages as read".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "account_key": { "type": "string" },
                    "message_keys": { "type": "array", "items": { "type": "string" } }
                },
                "required": ["account_key", "message_keys"]
            }),
        },
        ToolDefinition {
            name: "mark_unread".into(),
            description: "Mark messages as unread".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "account_key": { "type": "string" },
                    "message_keys": { "type": "array", "items": { "type": "string" } }
                },
                "required": ["account_key", "message_keys"]
            }),
        },
        ToolDefinition {
            name: "archive".into(),
            description: "Archive conversations".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "account_key": { "type": "string" },
                    "conversation_keys": { "type": "array", "items": { "type": "string" } }
                },
                "required": ["account_key", "conversation_keys"]
            }),
        },
        ToolDefinition {
            name: "set_priority".into(),
            description: "Set priority flags on conversations".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "account_key": { "type": "string" },
                    "conversation_keys": { "type": "array", "items": { "type": "string" } },
                    "urgent": { "type": "boolean" },
                    "important": { "type": "boolean" }
                },
                "required": ["account_key", "conversation_keys", "urgent", "important"]
            }),
        },
        // ── Privileged ─────────────────────────────────────────────
        ToolDefinition {
            name: "send_message".into(),
            description: "Send an email, optionally as a threaded reply (in_reply_to = message key). Goes through the durable outbox; requires approval unless auto-approve is on.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "account_key": { "type": "string" },
                    "to": { "type": "string", "description": "Comma-separated addresses" },
                    "from": { "type": "string", "description": "inbox2-hosted orgs only: sending address (default: the one the thread was sent to, else your primary)" },
                    "cc": { "type": "string", "description": "Comma-separated addresses" },
                    "bcc": { "type": "string", "description": "Comma-separated addresses" },
                    "subject": { "type": "string" },
                    "body_html": { "type": "string" },
                    "body_plain": { "type": "string" },
                    "in_reply_to": { "type": "string", "description": "Message key being replied to" }
                },
                "required": ["account_key", "to", "subject"]
            }),
        },
        ToolDefinition {
            name: "trash".into(),
            description: "Move conversations to trash (requires approval unless auto-approve is on)".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "account_key": { "type": "string" },
                    "conversation_keys": { "type": "array", "items": { "type": "string" } }
                },
                "required": ["account_key", "conversation_keys"]
            }),
        },
        ToolDefinition {
            name: "delete".into(),
            description: "Permanently delete conversations, bypassing trash (requires approval unless auto-approve is on)".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "account_key": { "type": "string" },
                    "conversation_keys": { "type": "array", "items": { "type": "string" } }
                },
                "required": ["account_key", "conversation_keys"]
            }),
        },
        ToolDefinition {
            name: "create_calendar_event".into(),
            description: "Create an event on a connected Google or Microsoft calendar (no guests, so nothing is sent to anyone). Returns the event key.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "account_key": { "type": "string", "description": "A Gmail or Microsoft account from list_accounts" },
                    "title": { "type": "string" },
                    "start_at": { "type": "string", "description": "RFC 3339 with the offset of `timezone` at that moment, e.g. 2026-10-26T14:00:00+01:00; YYYY-MM-DD when all_day" },
                    "end_at": { "type": "string", "description": "Same form as start_at; for all_day the day after the last day" },
                    "timezone": { "type": "string", "description": "IANA zone, e.g. Europe/Amsterdam. Required unless all_day" },
                    "all_day": { "type": "boolean" },
                    "description": { "type": "string" },
                    "location": { "type": "string" },
                    "calendar": { "type": "string", "description": "Calendar name (default: the account's primary calendar)" }
                },
                "required": ["account_key", "title", "start_at", "end_at"]
            }),
        },
        // ── WhatsApp (read only, macOS: WhatsApp Desktop's own database) ──
        ToolDefinition {
            name: "whatsapp_chats".into(),
            description: "List WhatsApp chats on this Mac, most recent first; `query` filters by chat name. Times are local.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "query": { "type": "string", "description": "Part of a person's or group's name" },
                    "limit": { "type": "integer", "default": 50 }
                }
            }),
        },
        ToolDefinition {
            name: "whatsapp_messages".into(),
            description: "The newest messages of one WhatsApp chat, oldest first. Pass the first message's id as `before` for the page before it.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "chat_id": { "type": "integer", "description": "From whatsapp_chats or whatsapp_search" },
                    "limit": { "type": "integer", "default": 50 },
                    "before": { "type": "integer", "description": "A message id: return the messages before it" }
                },
                "required": ["chat_id"]
            }),
        },
        ToolDefinition {
            name: "whatsapp_search".into(),
            description: "Search WhatsApp message text across all chats; every word must appear. Newest first.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "query": { "type": "string" },
                    "limit": { "type": "integer", "default": 50 }
                },
                "required": ["query"]
            }),
        },
    ]
}
