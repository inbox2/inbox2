pub mod ai;
pub mod local_agents;
pub mod mcp;
mod mcp_client;
pub mod sync;
pub mod vector;

mod alert_sound;
mod app_icon;
mod commands;
mod disk_finder;
mod setup;
mod shutdown;
mod tray;
mod updater;
mod whatsapp;
mod whatsapp_actions;
#[cfg(target_os = "macos")]
mod whatsapp_ax;
mod whatsapp_groups;
pub mod whatsapp_lore;

use tauri::{Emitter, Manager};
use tauri_plugin_sql::{Migration, MigrationKind};

use sync::commands::SyncState;

// The bundle identifier and per-user data dir resolution now live in `inbox2-core`
// (the headless binaries and the future mobile core need them without an
// `AppHandle`). Re-exported so existing `app_lib::default_data_dir` /
// `app_lib::BUNDLE_ID` callers are unchanged.
pub use inbox2_core::{default_data_dir, BUNDLE_ID};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let migrations = vec![Migration {
        version: 1,
        description: "create_schema",
        sql: inbox2_core::SCHEMA_SQL,
        kind: MigrationKind::Up,
    }];

    let ctx = tauri::generate_context!();
    let mut builder = tauri::Builder::default();
    // macOS: register tauri-nspanel so the new-mail popup can be turned into a
    // non-activating panel (see commands::convert_notification_to_panel).
    #[cfg(target_os = "macos")]
    {
        builder = builder.plugin(tauri_nspanel::init());
    }
    // Windows/Linux: a second launch (re-opening the app, or following an
    // inbox2:// deep link) starts a new process instead of routing to the
    // running one as macOS does natively. Register single-instance FIRST (before
    // deep-link) so it can forward argv to the live instance; the `deep-link`
    // feature then re-emits the URL through the deep-link plugin's on_open_url.
    #[cfg(any(target_os = "windows", target_os = "linux"))]
    {
        builder = builder.plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            tray::focus_main(app);
        }));
    }
    // Self-hosted auto-update, only when this build carries `plugins.updater` —
    // i.e. a release build (tauri.release.conf.json). The plugin refuses to
    // initialise without that config and takes the whole app down with it, so a
    // dev build or a local install:app build must not register it.
    // updater::updates_supported() is the same test, for the web side.
    let builder = if ctx.config().plugins.0.contains_key("updater") {
        builder.plugin(tauri_plugin_updater::Builder::new().build())
    } else {
        builder
    };
    builder
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_opener::init())
        // Copy from the notification panel, which can never be key window (navigator.clipboard needs focus).
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_drag::init())
        // Relaunch-after-install (process).
        .plugin(tauri_plugin_process::init())
        // HTTP client used for CORS-bound third-party APIs (Apollo enrichment).
        .plugin(tauri_plugin_http::init())
        // Native OS notifications — used by the "system" notification mode.
        .plugin(tauri_plugin_notification::init())
        // Deny-list the runtime-created notification window: its geometry is
        // computed fresh each alert (top-right, fixed width, height auto-fit to
        // the card stack). Letting the plugin persist + restore it would clobber
        // that with a stale size — e.g. an old 376px width that clips the wider
        // cards on the left.
        .plugin(
            // Drop MAXIMIZED from the tracked flags: on macOS (transparent window
            // + Overlay titlebar) is_maximized() is unreliable, so the plugin
            // persisted a spurious maximized state and relaunched maximized even
            // when the last session wasn't. Without it, the plugin restores the
            // real last SIZE + POSITION — which is what "restore my window" means.
            tauri_plugin_window_state::Builder::new()
                .with_state_flags(
                    tauri_plugin_window_state::StateFlags::all()
                        & !tauri_plugin_window_state::StateFlags::MAXIMIZED,
                )
                .with_denylist(&["notification", tray::WINDOW])
                .build(),
        )
        .plugin(
            tauri_plugin_sql::Builder::default()
                .add_migrations("sqlite:inbox2.db", migrations)
                .build(),
        )
        .plugin(
            tauri_plugin_log::Builder::default()
                .level(log::LevelFilter::Info)
                // html5ever (pulled in by ammonia when sanitizing email HTML)
                // spams "foster parenting not implemented" WARNs on any message
                // with tables/malformed markup. Harmless and unactionable — mute
                // the crate so it doesn't drown the sync log.
                .level_for("html5ever", log::LevelFilter::Off)
                // Default is 40 KB, which rotates away crash context within
                // minutes of busy sync logging. Keep ~10 MB so a shutdown
                // reason is still in the file when we go looking.
                .max_file_size(10_000_000)
                .build(),
        )
        .plugin(
            // Route links clicked inside sandboxed email iframes to the system
            // browser. WKWebView doesn't deliver iframe-document click events to
            // parent JS, so we intercept at the navigation layer: cancel the
            // in-frame navigation to an external URL and hand it to the frontend
            // (which opens it in a new system-browser tab).
            tauri::plugin::Builder::<tauri::Wry>::new("email-link-router")
                .on_navigation(|webview, url| {
                    // Only police the main app webview, where email iframes live.
                    if webview.label() != "main" {
                        return true;
                    }
                    let s = url.as_str();
                    log::info!("[link-router] nav main: {}", s);
                    // Allow the app's own origins + internal schemes (initial load,
                    // Vite HMR reloads, iframe srcdoc, proxied blob:/data: images).
                    let internal = s.starts_with("tauri://")
                        || s.starts_with("http://localhost")
                        || s.starts_with("http://127.0.0.1")
                        || s.starts_with("http://tauri.localhost")
                        || s.starts_with("https://tauri.localhost")
                        || s.starts_with("about:")
                        || s.starts_with("data:")
                        || s.starts_with("blob:");
                    if internal {
                        return true;
                    }
                    if s.starts_with("http://") || s.starts_with("https://") {
                        let _ = webview.emit("open-external-link", s.to_string());
                        return false; // cancel the in-frame navigation
                    }
                    true
                })
                .build(),
        )
        // Local WhatsApp media + avatars, confined to WhatsApp's container (whatsapp.rs).
        .register_asynchronous_uri_scheme_protocol("wamedia", |_ctx, request, responder| {
            tauri::async_runtime::spawn_blocking(move || responder.respond(whatsapp::serve_media(&request)));
        })
        .setup(|app| {
            setup::build_app_menu(app)?;
            setup::install_panic_hook();
            log::info!("Starting inbox2 desktop v{}", env!("CARGO_PKG_VERSION"));
            setup::apply_window_chrome(app);
            setup::spawn_display_watcher(app);

            // The SyncStore opens its own rusqlite connection (WAL mode) to the
            // same DB that tauri-plugin-sql manages.
            let app_data_dir = app
                .path()
                .app_data_dir()
                .expect("failed to resolve app data dir");
            let db_path = app_data_dir.join("inbox2.db");

            let store = setup::open_sync_store(app, &db_path, &app_data_dir);
            let (engine, bus_client) = setup::init_engine(app, store, &app_data_dir);
            setup::maybe_start_mcp(&app_data_dir, &engine);

            // Clone the engine Arc before moving it into SyncState, so the
            // AI/vector subsystems can still access the store's DB connection.
            let engine_for_vector = engine.clone();

            app.manage(SyncState {
                engine,
                bus: bus_client,
            });

            setup::register_oauth_deeplink_listener(app);
            setup::init_ai_subsystems(app, engine_for_vector, &app_data_dir);

            // Poll for a newer signed build (non-blocking). Emits
            // `update://available` whenever one is published.
            updater::check_on_startup(app.handle());

            // Menu bar item + popover. Not fatal: the app is whole without it.
            if let Err(e) = tray::init(app.handle()) {
                log::warn!("tray: init failed: {e}");
            }
            // Disk in Finder: FileVault check + a 30 s nudge to the extension.
            disk_finder::start(app.handle());

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            disk_finder::disk_finder_status,
            disk_finder::disk_finder_enable,
            disk_finder::disk_finder_update,
            disk_finder::disk_finder_disable,
            disk_finder::disk_finder_pause,
            disk_finder::disk_finder_open,
            disk_finder::disk_finder_open_system_settings,
            app_icon::set_app_icon,
            whatsapp::wa_status,
            whatsapp::wa_chats,
            whatsapp::wa_messages,
            whatsapp::wa_search,
            whatsapp::wa_open_media,
            whatsapp::wa_open_privacy_settings,
            whatsapp::wa_chat_media,
            whatsapp::wa_save_media,
            whatsapp::wa_reveal_media,
            whatsapp_actions::wa_actions_status,
            whatsapp_actions::wa_request_accessibility,
            whatsapp_actions::wa_open_accessibility_settings,
            whatsapp_actions::wa_open_in_whatsapp,
            whatsapp_actions::wa_send,
            whatsapp_actions::wa_pick_files,
            commands::drag_fallback_icon,
            commands::attachment_cache_path,
            whatsapp_lore::wa_lore_set_enabled,
            whatsapp_lore::wa_lore_set_done,
            whatsapp_groups::wa_group_set_tracked,
            whatsapp_groups::wa_group_set_ignored,
            whatsapp_groups::wa_group_day_summary,
            whatsapp_groups::wa_group_todo_set_done,
            alert_sound::play_alert_sound,
            commands::get_file_type_icon,
            commands::js_log,
            commands::quit_app,
            commands::convert_notification_to_panel,
            commands::popup_windows_supported,
            commands::software_rendering,
            tray::tray_set_title,
            tray::tray_hide,
            commands::save_and_open_attachment,
            commands::save_attachment_as,
            commands::open_cached_attachment,
            commands::read_cached_attachment,
            commands::cache_attachment_bytes,
            updater::check_for_updates,
            updater::download_and_install_update,
            sync::commands::add_external_account,
            sync::commands::add_meta_account,
            sync::commands::remove_external_account,
            sync::commands::vault_status,
            sync::commands::enable_cloud_backup,
            sync::commands::disable_cloud_backup,
            sync::commands::unlock_vault,
            sync::commands::rotate_vault,
            sync::commands::clear_vault_session,
            sync::commands::list_cloud_backed_credentials,
            sync::commands::restore_from_cloud,
            sync::commands::set_account_cloud_backup,
            sync::commands::set_open_tracking,
            sync::commands::get_open_tracking,
            sync::commands::get_message_opens,
            sync::commands::list_external_accounts,
            sync::commands::claim_reauth_prompt,
            sync::commands::reorder_external_accounts,
            sync::commands::start_sync,
            sync::commands::stop_sync,
            sync::commands::resync_account,
            sync::commands::register_push,
            sync::commands::deregister_push,
            sync::commands::ingest_meta_event,
            sync::commands::get_sync_status,
            sync::commands::get_syncing_accounts,
            sync::commands::get_sync_log,
            sync::commands::get_account_diagnostics,
            sync::commands::queue_writeback_action,
            sync::commands::list_external_folders,
            sync::commands::get_account_credentials,
            sync::commands::update_external_account_status,
            sync::commands::set_api_context,
            sync::commands::mx_sync,
            sync::commands::mx_action,
            sync::commands::mx_forget,
            sync::commands::mx_set_domain_keys,
            sync::commands::start_device_link,
            sync::commands::get_rails_token,
            sync::commands::set_secret,
            sync::commands::get_secret,
            sync::commands::clear_secret,
            sync::commands::fetch_message,
            sync::commands::provider_search,
            sync::commands::download_attachment,
            sync::commands::get_message_source,
            sync::commands::send_message,
            sync::commands::list_outbox,
            sync::commands::retry_outbox_message,
            sync::commands::perform_conversation_action,
            sync::commands::calendar_respond_event,
            sync::commands::calendar_create_event,
            sync::commands::calendar_delete_event,
            sync::commands::calendar_reschedule_event,
            sync::commands::invite_for_attachment,
            sync::commands::respond_to_invite,
            sync::commands::add_invite_to_calendar,
            sync::commands::detected_invite,
            sync::commands::add_detected_meeting_to_calendar,
            sync::commands::set_priority,
            sync::commands::clear_priority,
            sync::commands::start_gmail_oauth,
            sync::commands::start_microsoft_oauth,
            sync::commands::start_instagram_oauth,
            sync::commands::complete_instagram_oauth,
            sync::commands::instagram_oauth_preview,
            sync::commands::clear_local_data,
            ai::commands::check_apple_foundation_models,
            ai::commands::download_ai_models,
            ai::commands::remove_ai_models,
            ai::commands::get_ai_model_disk_usage,
            ai::commands::warmup_ai_models,
            ai::commands::ai_sentiment,
            ai::commands::ai_intent,
            ai::commands::ai_embedding,
            ai::generative_commands::initialize_generative,
            ai::generative_commands::generative_smart_replies,
            ai::generative_commands::generative_summarize,
            ai::generative_commands::generative_generate,
            ai::bridge_commands::bridge_brief,
            ai::bridge_commands::bridge_validate_openai,
            ai::generative_commands::stop_generative,
            sync::commands::get_processing_window,
            sync::commands::set_processing_window,
            sync::commands::triage_progress,
            sync::commands::set_ai_config,
            sync::commands::triage_eval,
            sync::commands::triage_eval_fixtures,
            sync::commands::triage_eval_case,
            sync::commands::retriage_conversation,
            sync::commands::set_conversation_space,
            sync::commands::set_conversation_label,
            sync::commands::get_effective_spaces,
            sync::commands::get_space_classify_enabled,
            sync::commands::set_space_classify_enabled,
            sync::commands::set_space_taxonomy,
            sync::commands::get_personal_spaces,
            sync::commands::set_personal_spaces,
            sync::commands::set_jev_key,
            sync::commands::validate_jev_key,
            sync::commands::get_triage_labels,
            sync::commands::lore_entities,
            sync::commands::lore_sent_add,
            sync::commands::lore_sent_list,
            sync::commands::lore_entity,
            sync::commands::lore_entity_rename,
            sync::commands::lore_entity_set_kind,
            sync::commands::lore_entity_merge,
            sync::commands::lore_entity_remove,
            sync::commands::lore_fact_edit,
            sync::commands::lore_fact_remove,
            sync::commands::lore_graph,
            sync::commands::set_triage_labels,
            sync::commands::get_lore_auto,
            sync::commands::set_lore_auto,
            ai::prompt_commands::prompts_get,
            ai::prompt_commands::prompts_set,
            ai::prompt_commands::prompts_reset,
            ai::lane_commands::model_lanes,
            ai::lane_commands::free_model_variants,
            ai::lane_commands::model_download,
            ai::lane_commands::model_delete,
            vector::commands::vector_search,
            vector::commands::vector_search_similar,
            vector::commands::vector_stats,
            vector::commands::vector_reindex,
            vector::commands::get_vector_setting,
            vector::commands::set_vector_setting,
            mcp::commands::mcp_info,
            mcp::commands::mcp_set_enabled,
            mcp::commands::mcp_set_agent_access,
            mcp_client::mcp_presets,
            mcp_client::mcp_list_connections,
            mcp_client::mcp_add_connection,
            mcp_client::mcp_reauth_connection,
            mcp_client::mcp_remove_connection,
            mcp_client::mcp_list_tools,
            mcp_client::mcp_call_tool,
            local_agents::commands::detect_local_agents,
            local_agents::commands::set_local_agent_enabled,
            local_agents::commands::list_local_rules,
            local_agents::commands::upsert_local_rule,
            local_agents::commands::delete_local_rule,
            local_agents::commands::preview_rule_matches,
            local_agents::commands::apply_rule_to_existing,
            local_agents::commands::run_rule_once,
            local_agents::commands::run_rule_on_conversation,
            local_agents::commands::test_run_agent,
            local_agents::commands::list_agent_runs,
            local_agents::commands::list_failed_agent_runs,
            local_agents::commands::retry_agent_run,
            local_agents::commands::list_agent_approvals,
            local_agents::commands::resolve_agent_approval,
        ])
        .on_menu_event(|app, event| {
            // ⌘W and ⌘Q are custom items (see setup) so we can route them to the
            // frontend instead of letting the OS close the window / quit.
            match event.id().as_ref() {
                "close_tab" => { let _ = app.emit_to("main", "menu:close-tab", ()); }
                "quit" => { let _ = app.emit_to("main", "menu:quit-request", ()); }
                _ => {}
            }
        })
        .on_window_event(|window, event| {
            // Don't quit immediately when the main window is asked to close
            // (red traffic light): route it through the same confirm dialog as
            // ⌘Q. The actual teardown + exit happens in the `quit_app` command
            // once the user confirms.
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" {
                    api.prevent_close();
                    let _ = window.app_handle().emit_to("main", "menu:quit-request", ());
                }
            }
        })
        .build(ctx)
        .expect("error while building tauri application")
        .run(|app_handle, event| match event {
            // Log the lifecycle so a shutdown always leaves a trace, and we can
            // distinguish a clean exit from a crash (which the panic hook logs).
            // A Disk page double-clicked in Finder: open it in inbox2 Disk (docs/Disk-Sync.md).
            #[cfg(target_os = "macos")]
            tauri::RunEvent::Opened { urls } => {
                for url in urls {
                    if let Ok(path) = url.to_file_path() {
                        disk_finder::open_page_file(&path);
                    }
                }
            }
            tauri::RunEvent::Ready => {
                log::info!("Lifecycle: app ready");
            }
            tauri::RunEvent::ExitRequested { code, .. } => {
                log::info!("Lifecycle: exit requested (code={code:?})");
                // Tear every pipeline down here (while the runtime is still
                // alive) — Exit force-terminates, so Drop impls won't run.
                shutdown::SHUTDOWN_ONCE.call_once(|| shutdown::graceful_shutdown(app_handle));

                // macOS: on a real quit, hard-exit now instead of returning into
                // wry's window/WKWebView teardown. That teardown intermittently
                // raises an Obj-C NSException which unwinds through tao's
                // CFRunLoop observer and aborts (a *foreign* exception can't cross
                // Rust's catch_unwind — `__rust_foreign_exception` → SIGABRT), so
                // the app "crashes on exit" even though our shutdown finished
                // cleanly. Everything needing explicit teardown is already done in
                // graceful_shutdown above, so exiting the process here is safe and
                // skips the crash. We must NOT do this on a restart
                // (code == RESTART_EXIT_CODE, i.e. the updater relaunch): that path
                // has to reach RunEvent::Exit for Tauri to spawn the new process.
                // The window-state plugin only persists on RunEvent::Exit, which we
                // skip — so replicate its save here first (it honors the same
                // `notification` denylist via the cache; flags match the builder).
                #[cfg(target_os = "macos")]
                if code != Some(tauri::RESTART_EXIT_CODE) {
                    use tauri_plugin_window_state::AppHandleExt;
                    let _ = app_handle.save_window_state(
                        tauri_plugin_window_state::StateFlags::all()
                            & !tauri_plugin_window_state::StateFlags::MAXIMIZED,
                    );
                    log::info!("Lifecycle: hard-exit (skipping wry teardown)");
                    std::process::exit(code.unwrap_or(0));
                }
            }
            tauri::RunEvent::Exit => {
                log::info!("Lifecycle: process exiting");
            }
            _ => {}
        });
}
