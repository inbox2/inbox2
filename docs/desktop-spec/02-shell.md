---
part: "02"
title: The Tauri shell
subtitle: The native layer that hosts the webview.
eyebrow: Shell
lede: The shell is the thin native layer around the webview. It owns the windows, the menu, the tray and the plugins, and hands everything else to the core.
---

## Windows

| Window | Created by | Shape |
|---|---|---|
| `main` | `tauri.conf.json` | 1440×900, transparent, macOS overlay title bar with the traffic lights, `hudWindow` vibrancy, background throttling off. |
| `tray` | `shell/tray.rs` | 620×780 popover at `/tray`, converted to an NSPanel on macOS so it never activates the app. Title text driven from the main window with `tray_set_title`. Not built on Linux. |
| `notification` | the UI (`web/hooks/useNewMessageNotifications.js`) | `/notification`, the card stack. `convert_notification_to_panel` turns it into a non-activating NSPanel; `canBecomeKeyWindow` and `acceptsFirstMouse:` are swizzled so a click acts without stealing focus. It hides on dismiss and stays alive. |

Custom chrome: the UI draws its own title bar and calls `startDragging()`, with 78 px of padding for the traffic lights. `data-tauri-drag-region` is unused because `startDragging()` works across screens.

### Windows and Linux

The overlay title bar is a macOS feature. On Windows and Linux `shell/setup.rs` removes the window decorations and the chrome bar's right end carries minimize, maximize and close (`WindowControls.jsx`); a double-click on the bar maximizes. The app menu is not set there, because it would draw a menu bar inside the window. Windows gets Acrylic through `set_effects`; Linux has no window material and keeps an opaque app background.

Windows was run for the first time on 2026-11-07, on a Windows 11 26H2 ARM64 virtual machine with the x64 build under emulation. The window chrome, the new-mail card and its actions, deep links, the single instance and the Credential Manager key all worked. Three things did not. A clean Windows has no Visual C++ runtime, and the exe imports it through the prebuilt ONNX Runtime, so the app exited at once with no log; the installer now carries the five runtime DLLs beside the exe (`shell/tauri.windows.conf.json`, `shell/vcredist/x64/`). The unread badge used `setBadgeCount`, a no-op on Windows; it is now an overlay icon drawn on a canvas (`hooks/useDockBadge.js`). The tray popover hung below the icon as on the macOS menu bar, which put it under the taskbar; it opens above the icon when the icon sits in the lower half of the screen. It also never closed on a click elsewhere, because focus sits in the WebView2 child and the OS window reports no blur; on Windows the shell polls whether the popover is still the active window and hides it when it is not.

> **Decision** The Windows installer bundles the Visual C++ runtime DLLs instead of running the redistributable (2026-11-07). The redistributable needs elevation and a 25 MB download inside the installer; five app-local DLLs cost 1 MB, win the DLL search order on every machine and need nothing from the person. Source: `docs/Desktop-Release.md`.

The Linux tray is a menu with Open and Quit, because the appindicator backend sends no click events, and the `/tray` popover is not built. Under Wayland no client may position a window, so `popup_windows_supported` returns false and the new-mail card becomes a system notification.

> **Decision** Windows and Linux draw their own window controls (2026-11-07). With `decorations: true` the native title bar sat above the chrome bar, a second strip with the same purpose. Source: `shell/setup.rs`, `docs/Tauri-Desktop.md`.

> **Decision** Background throttling is disabled on the main window (found 2026-09-19). WebKit suspended the hidden webview, so ActionCable frames for new MX mail and push resync hints never arrived. Source: `docs/Tauri-Desktop.md`.

> **Decision** The notification and tray windows are non-activating NSPanels. A plain window activated the app and stole focus from whatever the person was doing. Source: `docs/Notifications.md`, `docs/Tauri-Desktop.md`.

## Menu, close and quit

![A new-message card](img/notif-mail.png "A card in the `notification` window: a non-activating panel, so Read, Archive, Delete and Reply act without taking focus from the app in front.")

`shell/setup.rs` builds the Inbox2, Edit and Window menus. Two items are custom and routed to the UI: `close_tab` (⌘W → `menu:close-tab`) and `quit` (→ `menu:quit-request`). Closing `main` is intercepted and turned into the same quit request; the UI confirms and then calls `quit_app`. Shutdown (`shell/shutdown.rs`) runs five steps:

1. Disconnect the adapters, with a 2 s cap.
2. Stop the Apple bridge and the LLM sidecar.
3. Release `engine.sock`.
4. Save the window state.
5. On macOS, hard-exit.

## Plugins and capabilities

`shell/lib.rs` registers these plugins:

| Plugin | Note |
|---|---|
| nspanel | macOS only |
| single-instance | Windows and Linux, with the `deep-link` feature; focuses `main` |
| updater | only when the config carries `plugins.updater` |
| deep-link, opener, clipboard-manager, drag, process, http, notification | |
| window-state | `notification` and `tray` excluded, MAXIMIZED masked out |
| sql | one migration, the schema |
| log | Info level, 10 MB files, html5ever muted |
| `email-link-router` (custom) | turns a navigation inside the email iframe into an `open-external-link` event |
| `wamedia` URI scheme | WhatsApp media |

`capabilities/default.json` grants `main`, `notification` and `tray` the window and webview permissions they need. It also grants `sql:allow-execute/select`, opener, clipboard write, drag, deep-link, notification, updater, `process:allow-restart`, and http to `https://api.apollo.io/*` only.

> **Watch out** A window or plugin API fails silently unless its permission is in `capabilities/default.json` (for example `allow-set-size`). Rebuild after changing it.

## Deep links and OAuth callbacks

Scheme `inbox2` (prod) or `inbox2-dev`. macOS routes URLs natively; Windows and Linux go through single-instance. The Linux `.deb` uses its own desktop entry template (`shell/deb/inbox2.desktop`) because Tauri's default registers the scheme but passes no URL to the binary. Every delivered URL is logged as `[deep-link]`. `register_oauth_deeplink_listener` parses `oauth-callback?code&state` and emits `gmail-oauth-callback` / `microsoft-oauth-callback`; Instagram has its own callback. The desktop device link (`shell/sync/commands/device_link.rs`) runs a loopback listener with PKCE. The browser signs in and approves the Mac, and the shell receives a device-scoped `ink_` key.

## The command boundary

183 commands, all in `generate_handler!`. The UI reaches them through thin wrappers (`web/lib/providers/index.js` for provider operations, `web/lib/localAgents.js`, `web/lib/mcp.js`, `web/lib/mcpClient.js`, `web/lib/secretStore.js`, `web/lib/ai/generative/tauriProvider.js`), never with bare strings scattered through components. Demo mode blocks the write commands (`DEMO_BLOCKED`).

| Area | Commands (file under `shell/`) |
|---|---|
| App and native | `get_file_type_icon`, `js_log`, `quit_app`, `convert_notification_to_panel`, `save_and_open_attachment`, `save_attachment_as`, `open_cached_attachment`, `read_cached_attachment`, `cache_attachment_bytes`, `drag_fallback_icon`, `attachment_cache_path`, `set_app_icon`, `play_alert_sound`, `tray_set_title`, `tray_hide`, `check_for_updates`, `download_and_install_update` (`commands.rs`, `app_icon.rs`, `alert_sound.rs`, `tray.rs`, `updater.rs`) |
| Accounts | `add_external_account`, `add_meta_account`, `remove_external_account`, `list_external_accounts`, `claim_reauth_prompt`, `reorder_external_accounts`, `get_account_credentials`, `update_external_account_status`, `set_open_tracking`, `get_open_tracking`, `get_message_opens` (`sync/commands/accounts.rs`) |
| Vault | `vault_status`, `enable_cloud_backup`, `disable_cloud_backup`, `unlock_vault`, `rotate_vault`, `clear_vault_session`, `list_cloud_backed_credentials`, `restore_from_cloud`, `set_account_cloud_backup` (`vault.rs`) |
| Sync control | `start_sync`, `stop_sync`, `resync_account`, `register_push`, `deregister_push`, `ingest_meta_event`, `get_sync_status`, `get_syncing_accounts`, `get_sync_log`, `get_account_diagnostics`, `queue_writeback_action`, `list_external_folders` (`sync_control.rs`) |
| MX | `mx_sync`, `mx_action`, `mx_forget`, `mx_set_domain_keys` (`mx.rs`) |
| Secrets and API | `set_api_context`, `get_rails_token`, `set_secret`, `get_secret`, `clear_secret` (`secrets.rs`); `start_device_link` (`device_link.rs`) |
| Interactive provider ops | `fetch_message`, `provider_search`, `download_attachment`, `get_message_source`, `send_message`, `list_outbox`, `retry_outbox_message`, `perform_conversation_action`, `calendar_respond_event`, `calendar_create_event`, `calendar_delete_event`, `calendar_reschedule_event`, `invite_for_attachment`, `respond_to_invite`, `add_invite_to_calendar`, `detected_invite`, `add_detected_meeting_to_calendar`, `set_priority`, `clear_priority` (`interactive.rs`) |
| OAuth | `start_gmail_oauth`, `start_microsoft_oauth`, `start_instagram_oauth`, `complete_instagram_oauth`, `instagram_oauth_preview` (`oauth.rs`); `clear_local_data` (`data.rs`) |
| Triage and spaces | `get/set_processing_window`, `triage_progress`, `set_ai_config`, `triage_eval`, `triage_eval_fixtures`, `triage_eval_case`, `retriage_conversation`, `set_conversation_space`, `set_conversation_label`, `get_effective_spaces`, `get/set_space_classify_enabled`, `set_space_taxonomy`, `get/set_personal_spaces`, `set_jev_key`, `validate_jev_key`, `get/set_triage_labels`, `get/set_lore_auto` (`triage.rs`) |
| Lore | `lore_entities`, `lore_entity`, `lore_graph` (`ontology.rs`) |
| AI tier A | `check_apple_foundation_models`, `download_ai_models`, `remove_ai_models`, `get_ai_model_disk_usage`, `warmup_ai_models`, `ai_sentiment`, `ai_intent`, `ai_embedding` (`ai/commands.rs`) |
| AI tier B and lanes | `initialize_generative`, `generative_smart_replies`, `generative_summarize`, `generative_generate`, `stop_generative`, `bridge_brief`, `bridge_validate_openai`, `prompts_get/set/reset`, `model_lanes`, `free_model_variants`, `model_download`, `model_delete` (`ai/generative_commands.rs`) |
| Vectors | `vector_search`, `vector_search_similar`, `vector_stats`, `vector_reindex`, `get/set_vector_setting` (`vector/commands.rs`) |
| MCP server and client | `mcp_info`, `mcp_set_enabled`, `mcp_set_agent_access` (`mcp/commands.rs`); `mcp_presets`, `mcp_list_connections`, `mcp_add_connection`, `mcp_reauth_connection`, `mcp_remove_connection`, `mcp_list_tools`, `mcp_call_tool` (`mcp_client.rs`) |
| Agentic filters | `detect_local_agents`, `set_local_agent_enabled`, `list_local_rules`, `upsert_local_rule`, `delete_local_rule`, `preview_rule_matches`, `apply_rule_to_existing`, `run_rule_once`, `run_rule_on_conversation`, `test_run_agent`, `list_agent_runs`, `list_failed_agent_runs`, `retry_agent_run`, `list_agent_approvals`, `resolve_agent_approval` (`local_agents/commands.rs`) |
| WhatsApp | `wa_status`, `wa_chats`, `wa_messages`, `wa_search`, `wa_open_media`, `wa_open_privacy_settings`, `wa_chat_media`, `wa_save_media`, `wa_reveal_media`, `wa_actions_status`, `wa_request_accessibility`, `wa_open_accessibility_settings`, `wa_open_in_whatsapp`, `wa_send`, `wa_pick_files`, `wa_lore_set_enabled`, `wa_lore_set_done`, `wa_group_set_tracked`, `wa_group_set_ignored`, `wa_group_day_summary`, `wa_group_todo_set_done` (`whatsapp*.rs`) |

A command is a thin function: it takes the engine from Tauri state and calls the core. When the process is a bus client, the command forwards the call over the socket to the host (`shell/sync/commands/mx.rs`).

```rust
#[tauri::command]
pub async fn mx_sync(
    state: State<'_, SyncState>,
    org: String,
    user_key: String,
    directory: Option<bool>,
    reconcile: Option<bool>,
) -> Result<Value, SyncError> {
    let (directory, reconcile) = (directory.unwrap_or(false), reconcile.unwrap_or(false));
    if let Some(bus) = &state.bus {
        // a bus client: the host runs the pass
        ...
    }
    ...
}
```

## Events

The core's `EventSink` emits `sync`, `new-message`, `calendar-changed`, `status`, `outbox-changed`, `triage-progress`, `triage-updated`, `space-updated`, `mx-sync` and `model-download`. On the desktop the sink is `TauriSink`. When the app is the bus host, the sink is a `CompositeSink` that also broadcasts to bus clients. A bus client re-emits what the host sends. The UI subscribes once, in `web/lib/sync-manager.js`, and re-broadcasts to hooks (`status` becomes `account-status`).

Shell-level events: `menu:close-tab`, `menu:quit-request`, `open-external-link`, the three OAuth callbacks, `tray-opened`, `update://available`, `update://progress`, `ai-model-download-progress`. Between windows the UI uses `emitTo`: `notification-show`, `notification-navigate`, `meeting-snooze`, `meeting-ignore`, `zone-dismiss`, `unread-adjust`, `notification-hidden`.

## macOS native pieces

- `swift-bridge/`: `FoundationModelsBridge`, a SwiftPM binary (macOS 26, `import FoundationModels`). `shell/ai/apple_bridge.rs` drives it over stdin/stdout JSON for check, generate, smart replies and summarize. How it is built and bundled into the app is unverified in code.
- `shell/ai/native_llm.rs`: the fallback `llama-server` sidecar with a GGUF model (default `qwen2.5-1.5b-instruct-gguf`).
- `shell/whatsapp.rs` reads WhatsApp Desktop's database; `shell/whatsapp_ax.rs` drives WhatsApp through the Accessibility API and `CGEvent` posts.
- `shell/alert_sound.rs`, `shell/app_icon.rs` (NSImage), `tauri-nspanel` for the two panels.
