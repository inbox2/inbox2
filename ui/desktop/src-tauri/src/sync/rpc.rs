//! Host-side RPC dispatch for the engine bus.
//!
//! Maps a method name + JSON params onto the same engine/store/interactive calls
//! the Tauri commands (`sync::commands`) wrap — but State-free, so it works in the
//! headless daemon too. Async engine methods are driven via a captured tokio
//! [`Handle`]; `call` runs on the bus server's per-connection std thread (not a
//! runtime worker), so `block_on` is safe here.

use std::sync::Arc;

use serde_json::{json, Value};
use tokio::runtime::Handle;

use crate::sync::engine::SyncEngine;
use crate::sync::ipc::RpcDispatch;
use crate::sync::model::*;

pub struct EngineRpc {
    engine: Arc<SyncEngine>,
    handle: Handle,
}

impl EngineRpc {
    pub fn new(engine: Arc<SyncEngine>, handle: Handle) -> Arc<Self> {
        Arc::new(Self { engine, handle })
    }
}

fn es<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

fn sfield(p: &Value, k: &str) -> Result<String, String> {
    p.get(k)
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| format!("missing string param: {k}"))
}

fn afield(p: &Value, k: &str) -> Result<Vec<String>, String> {
    p.get(k)
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
        .ok_or_else(|| format!("missing array param: {k}"))
}

fn bfield(p: &Value, k: &str) -> bool {
    p.get(k).and_then(|v| v.as_bool()).unwrap_or(false)
}

impl RpcDispatch for EngineRpc {
    fn call(&self, method: &str, params: Value) -> Result<Value, String> {
        let e = &self.engine;
        let h = &self.handle;

        match method {
            // ── reads (also available to clients straight from SQLite) ──
            "list_accounts" => {
                let accounts = e.store().list_accounts().map_err(es)?;
                Ok(json!(accounts
                    .into_iter()
                    .map(|a| json!({
                        "key": a.key,
                        "display_name": a.display_name,
                        "email_address": a.email_address,
                        "provider_type": a.provider_type.as_str(),
                        "status": a.status.as_str(),
                        "error_message": a.error_message,
                        "avatar_url": a.avatar_url,
                    }))
                    .collect::<Vec<_>>()))
            }
            "list_folders" => {
                let ak = sfield(&params, "account_key")?;
                let folders = e.store().get_folders_for_account(&ak).map_err(es)?;
                Ok(json!(folders
                    .into_iter()
                    .map(|f| json!({
                        "key": f.key,
                        "provider_name": f.provider_name,
                        "well_known_role": f.role.as_ref().map(|r| r.as_str()),
                        "sync_enabled": f.sync_enabled,
                    }))
                    .collect::<Vec<_>>()))
            }
            "get_sync_status" => {
                let statuses = h.block_on(e.account_statuses());
                Ok(json!(statuses
                    .into_iter()
                    .map(|(key, status)| json!({ "key": key, "status": status.as_str() }))
                    .collect::<Vec<_>>()))
            }
            "get_syncing_accounts" => {
                let keys = e.syncing_accounts();
                Ok(json!(keys))
            }
            "get_sync_log" => Ok(json!(e.recent_sync_events())),
            "get_account_diagnostics" => {
                let ak = sfield(&params, "account_key")?;
                h.block_on(e.account_diagnostics(&ak)).map_err(es)
            }

            // ── engine configuration / account management ──
            "set_api_context" => {
                let api_base = sfield(&params, "api_base")?;
                let rails_jwt = sfield(&params, "rails_jwt")?;
                h.block_on(e.set_api_context(api_base, rails_jwt));
                Ok(Value::Null)
            }
            "get_rails_token" => Ok(match e.persisted_rails_token() {
                Some(t) => Value::String(t),
                None => Value::Null,
            }),
            "set_secret" => {
                let name = sfield(&params, "name")?;
                let value = sfield(&params, "value")?;
                let key = format!("{}{name}", crate::sync::commands::SECRET_KV_PREFIX);
                e.store().store_app_secret(&key, &value).map_err(es)?;
                Ok(Value::Null)
            }
            "get_secret" => {
                let name = sfield(&params, "name")?;
                let key = format!("{}{name}", crate::sync::commands::SECRET_KV_PREFIX);
                Ok(match e.store().get_app_secret(&key).map_err(es)? {
                    Some(v) => Value::String(v),
                    None => Value::Null,
                })
            }
            "clear_secret" => {
                let name = sfield(&params, "name")?;
                let key = format!("{}{name}", crate::sync::commands::SECRET_KV_PREFIX);
                e.store().delete_app_secret(&key).map_err(es)?;
                Ok(Value::Null)
            }
            "add_external_account" => {
                let request: crate::sync::commands::AddAccountRequest =
                    serde_json::from_value(params).map_err(es)?;
                let resp = h
                    .block_on(crate::sync::commands::create_account_on_engine(e, request))
                    .map_err(es)?;
                serde_json::to_value(resp).map_err(es)
            }
            "add_meta_account" => {
                let request: crate::sync::commands::AddMetaAccountRequest =
                    serde_json::from_value(params).map_err(es)?;
                let resp = h
                    .block_on(crate::sync::commands::create_meta_account_on_engine(e, request))
                    .map_err(es)?;
                serde_json::to_value(resp).map_err(es)
            }

            // ── sync control ──
            // ── MX mirror (docs/MX-Sync.md) ──
            "mx_sync" => {
                let opts = crate::sync::mx_sync::MxSyncOptions {
                    directory: params.get("directory").and_then(Value::as_bool).unwrap_or(false),
                    reconcile: params.get("reconcile").and_then(Value::as_bool).unwrap_or(false),
                };
                let report = h
                    .block_on(e.mx_sync(&sfield(&params, "org")?, &sfield(&params, "user_key")?, opts))
                    .map_err(es)?;
                Ok(serde_json::to_value(report).unwrap_or(Value::Null))
            }
            "mx_action" => {
                let threads: Vec<String> = params
                    .get("threads")
                    .and_then(|t| serde_json::from_value(t.clone()).ok())
                    .ok_or_else(|| "missing threads".to_string())?;
                h.block_on(e.mx_action(&sfield(&params, "org")?, &threads, &sfield(&params, "action")?))
                    .map_err(es)?;
                Ok(Value::Null)
            }
            "mx_send" => {
                let message = params.get("message").cloned().ok_or_else(|| "missing param: message".to_string())?;
                let result = h.block_on(e.mx_send(&sfield(&params, "org")?, &message)).map_err(es)?;
                serde_json::to_value(result).map_err(es)
            }
            "mx_outbox_retry" => {
                let result = h.block_on(e.mx_outbox_retry(&sfield(&params, "key")?)).map_err(es)?;
                serde_json::to_value(result).map_err(es)
            }
            "mx_forget" => {
                h.block_on(e.mx_forget(&sfield(&params, "org")?)).map_err(es)?;
                Ok(Value::Null)
            }
            "start_sync" => {
                let ak = sfield(&params, "account_key")?;
                h.block_on(e.connect_and_sync(&ak)).map_err(es)?;
                Ok(Value::Null)
            }
            "stop_sync" => {
                let ak = sfield(&params, "account_key")?;
                h.block_on(e.remove_account(&ak)).map_err(es)?;
                Ok(Value::Null)
            }
            "resync_account" => {
                let ak = sfield(&params, "account_key")?;
                let folders = e.store().get_folders_for_account(&ak).map_err(es)?;
                for folder in &folders {
                    e.store().invalidate_folder_uids(&ak, &folder.key).map_err(es)?;
                }
                h.block_on(e.connect_and_sync(&ak)).map_err(es)?;
                Ok(Value::Null)
            }

            // ── cloud push (Gmail/Office365) ──
            "register_push" => {
                let ak = sfield(&params, "account_key")?;
                let registered = h.block_on(e.register_push(&ak)).map_err(es)?;
                Ok(json!({ "registered": registered }))
            }
            "deregister_push" => {
                let ak = sfield(&params, "account_key")?;
                h.block_on(e.deregister_push(&ak)).map_err(es)?;
                Ok(Value::Null)
            }

            // ── credential vault (zero-knowledge cloud backup) ──
            "vault_status" => serde_json::to_value(e.vault_status().map_err(es)?).map_err(es),
            "enable_cloud_backup" => {
                let pw = sfield(&params, "password")?;
                let key = h.block_on(e.enable_cloud_backup(&pw)).map_err(es)?;
                Ok(json!(key))
            }
            "disable_cloud_backup" => {
                h.block_on(e.disable_cloud_backup()).map_err(es)?;
                Ok(Value::Null)
            }
            "unlock_vault" => {
                let pw = sfield(&params, "password")?;
                h.block_on(e.unlock_vault(&pw)).map_err(es)?;
                Ok(Value::Null)
            }
            "rotate_vault" => {
                let pw = sfield(&params, "new_password")?;
                h.block_on(e.rotate_vault(&pw)).map_err(es)?;
                Ok(Value::Null)
            }
            "clear_vault_session" => {
                e.clear_vault_session();
                Ok(Value::Null)
            }
            "list_cloud_backed_credentials" => {
                let metas = h.block_on(e.list_cloud_backups()).map_err(es)?;
                serde_json::to_value(metas).map_err(es)
            }
            "restore_from_cloud" => {
                let pw = sfield(&params, "password")?;
                let n = h.block_on(e.restore_from_cloud(&pw)).map_err(es)?;
                Ok(json!(n))
            }
            "set_account_cloud_backup" => {
                let ak = sfield(&params, "account_key")?;
                let enabled = bfield(&params, "enabled");
                e.store().set_account_backup_enabled(&ak, enabled).map_err(es)?;
                if enabled {
                    e.store().mark_backup_dirty(&ak).map_err(es)?;
                }
                Ok(Value::Null)
            }

            // ── Meta webhook relay (Instagram/Messenger/WhatsApp) ──
            "ingest_meta_event" => {
                let ek = sfield(&params, "event_key")?;
                let applied = h.block_on(e.ingest_meta_event(&ek)).map_err(es)?;
                Ok(json!({ "applied": applied }))
            }

            // ── on-demand message ops ──
            "fetch_message" => {
                let ak = sfield(&params, "account_key")?;
                let mk = sfield(&params, "message_key")?;
                let provider = e.interactive_provider(&ak).map_err(es)?;
                let fetched = h.block_on(provider.fetch_message(&mk)).map_err(es)?;
                serde_json::to_value(fetched).map_err(es)
            }
            "get_message_source" => {
                let ak = sfield(&params, "account_key")?;
                let mk = sfield(&params, "message_key")?;
                let provider = e.interactive_provider(&ak).map_err(es)?;
                let raw = h.block_on(provider.get_message_source(&mk)).map_err(es)?;
                Ok(json!({ "raw": raw }))
            }
            "download_attachment" => {
                let ak = sfield(&params, "account_key")?;
                let mk = sfield(&params, "message_key")?;
                let att_id = sfield(&params, "attachment_id")?;
                let filename = sfield(&params, "filename")?;
                let provider = e.interactive_provider(&ak).map_err(es)?;
                let bytes = h
                    .block_on(provider.download_attachment(&mk, &att_id))
                    .map_err(es)?;
                // Write the bytes to the host's shared per-message cache and hand
                // the client the path (host + clients share the machine + data dir),
                // so attachment bytes never traverse the line-based JSON bus. Same
                // message-namespaced scheme the desktop + agent runner use.
                let path = e
                    .store()
                    .cache_message_attachment(&ak, &mk, &filename, &bytes)
                    .map_err(es)?;
                Ok(json!({ "path": path.to_string_lossy(), "size": bytes.len() }))
            }
            "send_message" => {
                let ak = sfield(&params, "account_key")?;
                let msg_val = params
                    .get("message")
                    .cloned()
                    .ok_or_else(|| "missing param: message".to_string())?;
                let msg = parse_outgoing(msg_val)?;
                let result = h.block_on(e.enqueue_send(&ak, msg)).map_err(es)?;
                serde_json::to_value(result).map_err(es)
            }
            "list_outbox" => {
                let ak = sfield(&params, "account_key")?;
                let items = e.outbox().list(&ak).map_err(es)?;
                serde_json::to_value(items).map_err(es)
            }
            "retry_outbox_message" => {
                let ak = sfield(&params, "account_key")?;
                let key = sfield(&params, "key")?;
                h.block_on(e.retry_outbox_message(&ak, &key)).map_err(es)?;
                Ok(Value::Null)
            }

            // ── conversation actions ──
            "perform_conversation_action" => {
                let ak = sfield(&params, "account_key")?;
                let convs = afield(&params, "conversation_keys")?;
                let action = sfield(&params, "action")?;
                h.block_on(e.perform_conversation_action(&ak, &convs, &action)).map_err(es)?;
                Ok(Value::Null)
            }
            "set_priority" => {
                let ak = sfield(&params, "account_key")?;
                let convs = afield(&params, "conversation_keys")?;
                h.block_on(e.set_conversation_priority(
                    &ak,
                    &convs,
                    bfield(&params, "urgent"),
                    bfield(&params, "important"),
                ))
                .map_err(es)?;
                Ok(Value::Null)
            }
            "clear_priority" => {
                let ak = sfield(&params, "account_key")?;
                let convs = afield(&params, "conversation_keys")?;
                h.block_on(e.clear_conversation_priority(&ak, &convs)).map_err(es)?;
                Ok(Value::Null)
            }
            "queue_writeback_action" => {
                let ak = sfield(&params, "account_key")?;
                let mk = sfield(&params, "message_key")?;
                let folder_key = params.get("folder_key").and_then(|v| v.as_str());
                let action_type = action_type_from_params(&params)?;
                let key = e
                    .writeback()
                    .enqueue(&ak, action_type, &mk, folder_key, None)
                    .map_err(es)?;
                Ok(json!({ "key": key }))
            }
            // Move to a folder (by key, well-known role or display name) — the
            // CLI's `v`; routes through the engine's durable write-back.
            "move_conversations" => {
                let ak = sfield(&params, "account_key")?;
                let convs = afield(&params, "conversation_keys")?;
                let folder = sfield(&params, "folder")?;
                h.block_on(e.move_conversations(&ak, &convs, &folder)).map_err(es)?;
                Ok(Value::Null)
            }
            "save_draft" => {
                let ak = sfield(&params, "account_key")?;
                let dk = sfield(&params, "draft_key")?;
                let msg_val = params
                    .get("message")
                    .cloned()
                    .ok_or_else(|| "missing param: message".to_string())?;
                let msg = parse_outgoing(msg_val)?;
                let result = h.block_on(e.enqueue_draft(&ak, &dk, msg)).map_err(es)?;
                serde_json::to_value(result).map_err(es)
            }

            // ── Spaces + triage labels (docs/Triage.md) ──
            "get_effective_spaces" => serde_json::to_value(e.store().effective_spaces()).map_err(es),
            "get_triage_labels" => serde_json::to_value(e.store().triage_labels()).map_err(es),
            "set_conversation_space" => {
                let ck = sfield(&params, "conversation_key")?;
                let slug = sfield(&params, "slug")?;
                inbox2_core::ai_worker::set_conversation_space(e, &ck, &slug)?;
                Ok(Value::Null)
            }
            "set_conversation_label" => {
                let ck = sfield(&params, "conversation_key")?;
                let label = sfield(&params, "label")?;
                inbox2_core::ai_worker::set_conversation_label(e, &ck, &label)?;
                Ok(Value::Null)
            }
            "retriage_conversation" => {
                let ck = sfield(&params, "conversation_key")?;
                let generator = e.generator_handle();
                let label = h.block_on(inbox2_core::ai_worker::rerun_jev(e, generator.as_ref(), &ck))?;
                Ok(Value::String(label))
            }

            // ── meeting invites (docs/Meeting-Invites.md) ──
            "invite_for_attachment" => {
                let ak = sfield(&params, "account_key")?;
                let mk = sfield(&params, "message_key")?;
                let att = sfield(&params, "attachment_id")?;
                let invite = h.block_on(e.invite_from_attachment(&ak, &mk, &att)).map_err(es)?;
                serde_json::to_value(invite).map_err(es)
            }
            "detected_invite" => {
                let ak = sfield(&params, "account_key")?;
                let mk = sfield(&params, "message_key")?;
                serde_json::to_value(e.detected_invite(&ak, &mk).map_err(es)?).map_err(es)
            }
            "respond_to_invite" => {
                let ak = sfield(&params, "account_key")?;
                let mk = sfield(&params, "message_key")?;
                let att = sfield(&params, "attachment_id")?;
                let response = sfield(&params, "response")?;
                h.block_on(e.respond_invite(&ak, &mk, &att, &response)).map_err(es)?;
                Ok(Value::Null)
            }
            "add_invite_to_calendar" => {
                let ak = sfield(&params, "account_key")?;
                let mk = sfield(&params, "message_key")?;
                let att = sfield(&params, "attachment_id")?;
                let cal = params.get("calendar_provider_id").and_then(|v| v.as_str()).map(String::from);
                let tz = params.get("device_timezone").and_then(|v| v.as_str()).map(String::from);
                let key = h
                    .block_on(e.add_invite_to_calendar(&ak, &mk, &att, cal, tz))
                    .map_err(es)?;
                Ok(json!({ "event_key": key }))
            }

            // ── calendar writes (provider ids supplied by the client, which has
            //    read access to the calendars/calendar_events tables) ──
            "calendar_create_event" => {
                let ak = sfield(&params, "account_key")?;
                let cal = sfield(&params, "calendar_provider_id")?;
                let draft = parse_draft(&params)?;
                let id = h
                    .block_on(e.create_calendar_event(&ak, &cal, draft))
                    .map_err(es)?;
                Ok(json!({ "provider_id": id }))
            }
            "calendar_update_event" => {
                let ak = sfield(&params, "account_key")?;
                let cal = sfield(&params, "calendar_provider_id")?;
                let ev = sfield(&params, "event_provider_id")?;
                let draft = parse_draft(&params)?;
                h.block_on(e.update_calendar_event(&ak, &cal, &ev, draft))
                    .map_err(es)?;
                Ok(Value::Null)
            }
            "calendar_delete_event" => {
                let ak = sfield(&params, "account_key")?;
                let cal = sfield(&params, "calendar_provider_id")?;
                let ev = sfield(&params, "event_provider_id")?;
                h.block_on(e.delete_calendar_event(&ak, &cal, &ev)).map_err(es)?;
                Ok(Value::Null)
            }
            "calendar_respond_event" => {
                let ak = sfield(&params, "account_key")?;
                let cal = sfield(&params, "calendar_provider_id")?;
                let ev = sfield(&params, "event_provider_id")?;
                let response = sfield(&params, "response")?;
                h.block_on(e.respond_calendar_event(&ak, &cal, &ev, &response))
                    .map_err(es)?;
                Ok(Value::Null)
            }

            // ── accounts / open tracking (docs/Open-Tracking.md) ──
            "remove_external_account" => {
                h.block_on(e.remove_account(&sfield(&params, "account_key")?)).map_err(es)?;
                Ok(Value::Null)
            }
            "get_open_tracking" => {
                let s = e.store().open_tracking_settings(&sfield(&params, "account_key")?).map_err(es)?;
                Ok(json!({ "enabled": s.enabled, "track_domain": s.track_domain }))
            }
            "set_open_tracking" => {
                let td = params.get("track_domain").and_then(Value::as_str)
                    .map(|s| s.trim().to_lowercase()).filter(|s| !s.is_empty());
                e.store()
                    .set_open_tracking(&sfield(&params, "account_key")?, bfield(&params, "enabled"), td.as_deref())
                    .map_err(es)?;
                Ok(Value::Null)
            }
            "get_message_opens" => {
                let body = e.store().message_body_html(&sfield(&params, "message_key")?).map_err(es)?.unwrap_or_default();
                serde_json::to_value(e.message_opens(&body)).map_err(es)
            }

            // ── Lore ontology (docs/Ontology.md) — same shapes as the lore_* Tauri commands ──
            "lore_graph" => {
                let conn = e.store().connection();
                let c = conn.lock();
                inbox2_core::ontology::mine_headers(&c).map_err(es)?;
                inbox2_core::ontology::graph(&c).map_err(es)
            }
            "lore_entities" | "lore_entity" => {
                let conn = e.store().connection();
                let c = conn.lock();
                inbox2_core::ontology::mine_headers(&c).map_err(es)?;
                if method == "lore_entities" {
                    let kind = params.get("kind").and_then(Value::as_str);
                    let q = params.get("q").and_then(Value::as_str);
                    inbox2_core::ontology::entities(&c, kind, q).map_err(es)
                } else {
                    inbox2_core::ontology::entity(&c, &sfield(&params, "id")?)
                        .map_err(es)?
                        .ok_or_else(|| "not found".to_string())
                }
            }

            // ── agentic filters (docs/Agentic-Filters.md) — the local_agents Tauri commands ──
            m if m.ends_with("_local_rule") || m.ends_with("_local_rules") || m.contains("agent") || m == "preview_rule_matches" || m == "apply_rule_to_existing" => {
                let a = crate::local_agents::HOSTED.get().ok_or("agentic filters are not running on this host")?;
                let rule = || -> Result<crate::local_agents::store::LocalRule, String> {
                    serde_json::from_value(params.get("rule").cloned().ok_or("missing param: rule")?).map_err(es)
                };
                let limit = |d: i64| params.get("limit").and_then(Value::as_i64).unwrap_or(d);
                match m {
                    "detect_local_agents" => {
                        let out: Vec<Value> = crate::local_agents::detect_all()
                            .into_iter()
                            .map(|d| {
                                let _ = a.store.upsert_detection(&d);
                                let enabled = a.store.is_enabled(&d.adapter_id) && d.installed;
                                let mut v = serde_json::to_value(&d).unwrap_or(Value::Null);
                                v["enabled"] = json!(enabled);
                                v
                            })
                            .collect();
                        Ok(json!(out))
                    }
                    "set_local_agent_enabled" => {
                        a.store.set_enabled(&sfield(&params, "adapter_id")?, bfield(&params, "enabled")).map_err(es)?;
                        Ok(Value::Null)
                    }
                    "list_local_rules" => serde_json::to_value(a.store.list_rules().map_err(es)?).map_err(es),
                    "upsert_local_rule" => Ok(json!(a.store.upsert_rule(&rule()?).map_err(es)?)),
                    "delete_local_rule" => {
                        a.store.delete_rule(&sfield(&params, "key")?).map_err(es)?;
                        Ok(Value::Null)
                    }
                    "preview_rule_matches" => {
                        const SCAN: i64 = 5000;
                        let (samples, total, scanned) = a.store.preview_rule_matches(&rule()?, 12, SCAN).map_err(es)?;
                        Ok(json!({ "samples": samples, "total": total, "scanned_capped": scanned as i64 >= SCAN }))
                    }
                    "apply_rule_to_existing" => {
                        Ok(json!(h.block_on(a.runner.apply_rule_to_existing(&sfield(&params, "rule_key")?, 5000))?))
                    }
                    "list_agent_runs" => {
                        let rows = match params.get("conversation_key").and_then(Value::as_str) {
                            Some(ck) => a.store.list_runs_for_conversation(ck, limit(50)),
                            None => a.store.list_runs(params.get("message_key").and_then(Value::as_str), limit(50)),
                        };
                        serde_json::to_value(rows.map_err(es)?).map_err(es)
                    }
                    "list_failed_agent_runs" => {
                        use crate::local_agents::store::RunStatus;
                        let rows = a.store
                            .list_runs_by_status(&[RunStatus::Failed.as_str(), RunStatus::Timeout.as_str()], limit(100))
                            .map_err(es)?;
                        serde_json::to_value(rows).map_err(es)
                    }
                    "retry_agent_run" => {
                        a.store.retry_run(&sfield(&params, "run_key")?).map_err(es)?;
                        Ok(Value::Null)
                    }
                    "list_agent_approvals" => serde_json::to_value(a.store.list_pending_approvals().map_err(es)?).map_err(es),
                    "resolve_agent_approval" => {
                        a.store.resolve_approval(&sfield(&params, "approval_key")?, bfield(&params, "approved")).map_err(es)?;
                        Ok(Value::Null)
                    }
                    other => Err(format!("unknown method: {other}")),
                }
            }

            // ── on-device AI + semantic search: only when the desktop app hosts ──
            "generative_smart_replies" | "generative_summarize" | "generative_generate" => {
                use crate::ai::generative_commands as gc;
                // The desktop's on-device backend when it hosts one; when there is
                // none, or it fails (e.g. replies it can't parse), the user's OpenAI
                // key — the triage worker's lane — so AI writing also works when only
                // engine_daemon hosts.
                let local = gc::HOSTED.get().filter(|g| {
                    h.block_on(async { *g.backend.lock().await != gc::GenerativeBackend::None })
                });
                let mut local_err: Option<String> = None;
                if let Some(g) = local {
                    let res: Result<Value, String> = match method {
                        "generative_smart_replies" => h
                            .block_on(gc::smart_replies_on(g, sfield(&params, "text")?, sfield(&params, "sender_name").unwrap_or_default()))
                            .map(|v| json!(v)),
                        "generative_summarize" => h.block_on(gc::summarize_on(g, sfield(&params, "text")?)).map(|v| json!(v)),
                        _ => h
                            .block_on(gc::generate_on(
                                g,
                                sfield(&params, "system")?,
                                sfield(&params, "prompt")?,
                                params.get("max_tokens").and_then(Value::as_u64).map(|n| n as u32),
                                params.get("temperature").and_then(Value::as_f64).map(|t| t as f32),
                            ))
                            .map(|v| json!(v)),
                    };
                    match res {
                        Ok(v) => return Ok(v),
                        Err(err) => local_err = Some(err),
                    }
                }
                // On-device AI chosen: never fall back to OpenAI with this mail.
                if !crate::sync::commands::openai_allowed(e.store()) {
                    return Err(local_err.unwrap_or_else(|| {
                        "On-device AI is chosen and its model runs in the desktop app — open Inbox2 to use it".into()
                    }));
                }
                let key = e
                    .store()
                    .get_app_secret(&format!("{}openai_api_key", crate::sync::commands::SECRET_KV_PREFIX))
                    .map_err(es)?
                    .filter(|k| !k.trim().is_empty());
                let Some(key) = key else {
                    return Err(local_err.unwrap_or_else(|| {
                        "No AI model available: add an OpenAI key in the desktop app (Settings › AI), or set up on-device AI there".into()
                    }));
                };
                use inbox2_core::bridge::{openai::OpenAiClient, prompts};
                let client = OpenAiClient::new(key);
                let model = prompts::openai_chat_model();
                match method {
                    "generative_summarize" => Ok(json!(h.block_on(client.generate(
                        &prompts::summarize_instructions(), &sfield(&params, "text")?, &model))?)),
                    "generative_smart_replies" => {
                        let user = format!("From: {}\n\n{}", sfield(&params, "sender_name").unwrap_or_default(), sfield(&params, "text")?);
                        let raw = h.block_on(client.generate(&prompts::smart_replies_instructions(), &user, &model))?;
                        Ok(json!(parse_reply_list(&raw)))
                    }
                    _ => Ok(json!(h.block_on(client.generate(&sfield(&params, "system")?, &sfield(&params, "prompt")?, &model))?)),
                }
            }
            "vector_search" | "vector_search_similar" => {
                let v = crate::vector::commands::HOSTED
                    .get()
                    .ok_or("Semantic search needs the on-device models — set up On-device AI in the desktop app")?;
                let limit = params.get("limit").and_then(Value::as_u64).map(|n| n as usize);
                let hits = if method == "vector_search" {
                    let account = params.get("account_key").and_then(Value::as_str).map(String::from);
                    h.block_on(crate::vector::commands::search_on(v, sfield(&params, "query")?, limit, account))?
                } else {
                    crate::vector::search::search_similar(&v.db_conn, &sfield(&params, "message_key")?, limit.unwrap_or(10))
                        .map_err(es)?
                };
                serde_json::to_value(hits).map_err(es)
            }

            // ── Settings › Intelligence (the desktop's On-device AI + Triage & sync) ──
            "get_processing_window" => Ok(json!(e.store().processing_window().as_str())),
            "set_processing_window" => {
                let w = inbox2_core::triage::ProcessingWindow::from_str(&sfield(&params, "window")?)
                    .ok_or("unknown processing window")?;
                e.store().set_processing_window(w).map_err(es)?;
                e.store().backfill_triage_queue().map_err(es)?;
                e.ai_scan_notify().notify_one();
                Ok(Value::Null)
            }
            "triage_progress" => {
                let p = e.store().triage_progress().map_err(es)?;
                Ok(inbox2_core::ai_worker::progress_json(e, &p))
            }
            "get_lore_auto" => serde_json::to_value(e.store().lore_auto()).map_err(es),
            "set_lore_auto" => {
                let s: inbox2_core::sync::store::LoreAutoSettings =
                    serde_json::from_value(params.get("settings").cloned().ok_or("missing param: settings")?).map_err(es)?;
                serde_json::to_value(e.store().set_lore_auto(s).map_err(es)?).map_err(es)
            }
            // Keys: validated with one real call, then saved to the engine's secret
            // store (where the desktop keeps them too) and applied at once.
            "set_jev_key" | "set_openai_key" => {
                let name = if method == "set_jev_key" { "typesafe_api_key" } else { "openai_api_key" };
                let secret = format!("{}{name}", crate::sync::commands::SECRET_KV_PREFIX);
                let key = params.get("key").and_then(Value::as_str).map(str::trim).filter(|k| !k.is_empty()).map(String::from);
                match &key {
                    Some(k) if method == "set_jev_key" => h.block_on(inbox2_core::typesafe::validate_key(&e.jev_endpoint(), k))?,
                    Some(k) => h.block_on(inbox2_core::bridge::agent::validate_openai(k))?,
                    None => {}
                }
                match &key {
                    Some(k) => e.store().store_app_secret(&secret, k).map_err(es)?,
                    None => e.store().delete_app_secret(&secret).map_err(es)?,
                }
                if method == "set_jev_key" {
                    e.set_jev_key(key);
                } else {
                    // A new key doesn't change the lane: on-device stays on-device.
                    let lane = if crate::sync::commands::openai_allowed(e.store()) {
                        inbox2_core::bridge::agent::GenSource::OpenAi
                    } else {
                        inbox2_core::bridge::agent::GenSource::OnDevice
                    };
                    let mut cfg = e.ai_config_snapshot().unwrap_or(inbox2_core::bridge::agent::BridgeConfig {
                        generation: lane,
                        openai_key: None,
                        model: inbox2_core::bridge::prompts::openai_chat_model(),
                        on_device_model: None,
                        concise: false,
                        weather: None,
                    });
                    cfg.openai_key = key;
                    e.set_ai_config(cfg);
                    e.ai_scan_notify().notify_one();
                }
                Ok(Value::Null)
            }
            "has_secret" => {
                let name = sfield(&params, "name")?;
                let v = e.store().get_app_secret(&format!("{}{name}", crate::sync::commands::SECRET_KV_PREFIX)).map_err(es)?;
                Ok(json!(v.is_some_and(|v| !v.trim().is_empty())))
            }

            // ── outbound MCP client, "Send to…" (docs/MCP-Client.md) ──
            // Store-level only: an OAuth sign-in needs the desktop's browser +
            // loopback, so a new OAuth server is added there; tokens work here.
            "mcp_presets" => serde_json::to_value(inbox2_core::mcp_client::presets()).map_err(es),
            "mcp_list_connections" => serde_json::to_value(inbox2_core::mcp_client::list_connections(e.store())?).map_err(es),
            "mcp_list_tools" => serde_json::to_value(h.block_on(inbox2_core::mcp_client::list_tools(e.store(), &sfield(&params, "id")?))?).map_err(es),
            "mcp_call_tool" => {
                let id = sfield(&params, "id")?;
                let tool = sfield(&params, "tool")?;
                log::info!("[mcp_client] {id}: calling {tool} (person pressed Create, over the bus)");
                let args = params.get("arguments").cloned().unwrap_or(Value::Null);
                serde_json::to_value(h.block_on(inbox2_core::mcp_client::call_tool(e.store(), &id, &tool, args))?).map_err(es)
            }
            "lore_sent_add" => serde_json::to_value(e.store().add_lore_sent(&sfield(&params, "item_key")?, &sfield(&params, "connection_name")?, params.get("summary").and_then(Value::as_str).unwrap_or("")).map_err(es)?).map_err(es),
            "lore_sent_list" => serde_json::to_value(e.store().lore_sent().map_err(es)?).map_err(es),
            "mcp_remove_connection" => {
                inbox2_core::mcp_client::remove_connection(e.store(), &sfield(&params, "id")?)?;
                Ok(Value::Null)
            }
            "mcp_add_token_connection" => {
                use inbox2_core::mcp_client::{self as mc, AuthKind, Connection, Credential, Probe, Status};
                let url = sfield(&params, "url")?.trim().to_string();
                mc::validate_url(&url)?;
                let token = params.get("token").and_then(Value::as_str).map(str::trim).filter(|t| !t.is_empty()).map(String::from);
                let auth = match h.block_on(mc::probe(&url, token.as_deref()))? {
                    Probe::Ok if token.is_some() => AuthKind::Token,
                    Probe::Ok => AuthKind::None,
                    Probe::NeedsAuth(_) if token.is_some() => return Err("The server rejected that token.".into()),
                    Probe::NeedsAuth(_) => return Err("This server signs in through the browser — add it in the desktop app (Settings › Integrations).".into()),
                };
                let name = params.get("name").and_then(Value::as_str).map(str::trim).filter(|n| !n.is_empty()).map(String::from)
                    .or_else(|| url::Url::parse(&url).ok().and_then(|u| u.host_str().map(String::from)))
                    .unwrap_or_else(|| url.clone());
                let conn = Connection { id: mc::new_id(), name, url, auth, status: Status::Connected, error: None };
                if let Some(t) = &token {
                    mc::save_credential(e.store(), &conn.id, &Credential::bearer(t))?;
                }
                mc::upsert_connection(e.store(), &conn)?;
                serde_json::to_value(conn).map_err(es)
            }

            // ── local WhatsApp (docs/Local-WhatsApp.md; macOS, read-only DB + AX sends) ──
            "wa_status" => serde_json::to_value(h.block_on(crate::whatsapp::wa_status())).map_err(es),
            "wa_chats" => serde_json::to_value(h.block_on(crate::whatsapp::wa_chats())?).map_err(es),
            "wa_messages" => {
                let chat_id = params.get("chat_id").and_then(Value::as_i64).ok_or("missing param: chat_id")?;
                let opt = |k: &str| params.get(k).and_then(Value::as_i64);
                serde_json::to_value(h.block_on(crate::whatsapp::wa_messages(chat_id, opt("before"), opt("around"), opt("limit")))?)
                    .map_err(es)
            }
            "wa_search" => {
                let limit = params.get("limit").and_then(Value::as_i64);
                serde_json::to_value(h.block_on(crate::whatsapp::wa_search(sfield(&params, "query")?, limit))?).map_err(es)
            }
            "wa_send" => {
                let chat_id = params.get("chat_id").and_then(Value::as_i64).ok_or("missing param: chat_id")?;
                let text = params.get("text").and_then(Value::as_str).map(String::from);
                let files = params.get("files").and_then(|f| serde_json::from_value(f.clone()).ok()).unwrap_or_default();
                h.block_on(crate::whatsapp_actions::wa_send(chat_id, text, files))?;
                Ok(Value::Null)
            }
            "wa_chat_media" => {
                let chat_id = params.get("chat_id").and_then(Value::as_i64).ok_or("missing param: chat_id")?;
                serde_json::to_value(h.block_on(crate::whatsapp::wa_chat_media(chat_id))?).map_err(es)
            }
            "wa_media_file" => Ok(json!(crate::whatsapp::media_file_path(&sfield(&params, "path")?)?)),
            "wa_open_in_whatsapp" => {
                let chat_id = params.get("chat_id").and_then(Value::as_i64).ok_or("missing param: chat_id")?;
                h.block_on(crate::whatsapp_actions::wa_open_in_whatsapp(chat_id))?;
                Ok(Value::Null)
            }
            "wa_lore_set_done" | "wa_group_todo_set_done" => {
                let id = params.get("id").and_then(Value::as_i64).ok_or("missing param: id")?;
                if method == "wa_lore_set_done" {
                    crate::whatsapp_lore::set_done(e.store(), id, bfield(&params, "done"))?;
                } else {
                    crate::whatsapp_groups::todo_set_done(e.store(), id, bfield(&params, "done"))?;
                }
                Ok(Value::Null)
            }

            other => Err(format!("unknown method: {other}")),
        }
    }
}

/// Parse an `OutgoingMessage`, reading any attachment given as a `path` (host
/// and client share the machine) so attachment bytes never ride the JSON bus.
fn parse_outgoing(mut msg_val: Value) -> Result<crate::sync::interactive::OutgoingMessage, String> {
    if let Some(atts) = msg_val.get_mut("attachments").and_then(Value::as_array_mut) {
        for att in atts.iter_mut() {
            let Some(path) = att.get("path").and_then(Value::as_str).map(String::from) else { continue };
            if att.get("data").is_some() {
                continue;
            }
            let bytes = std::fs::read(&path).map_err(|e| format!("attachment {path}: {e}"))?;
            if let Some(obj) = att.as_object_mut() {
                obj.remove("path");
                obj.entry("filename").or_insert_with(|| {
                    json!(std::path::Path::new(&path).file_name().and_then(|n| n.to_str()).unwrap_or("attachment"))
                });
                obj.insert("data".into(), json!(bytes));
            }
        }
    }
    serde_json::from_value(msg_val).map_err(es)
}

/// The smart-reply prompt asks for a JSON array of strings; tolerate a fenced
/// block, and fall back to one suggestion per line.
fn parse_reply_list(raw: &str) -> Vec<String> {
    let t = raw.trim().trim_start_matches("```json").trim_start_matches("```").trim_end_matches("```").trim();
    if let Ok(list) = serde_json::from_str::<Vec<String>>(t) {
        return list.into_iter().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
    }
    t.lines()
        .map(|l| l.trim().trim_start_matches(['-', '*', '•']).trim().trim_matches('"').to_string())
        .filter(|l| !l.is_empty())
        .take(3)
        .collect()
}

/// Parse the `event` object into an `EventDraft`.
fn parse_draft(params: &Value) -> Result<crate::sync::calendar::EventDraft, String> {
    let event = params
        .get("event")
        .cloned()
        .ok_or_else(|| "missing param: event".to_string())?;
    serde_json::from_value(event).map_err(es)
}

fn action_type_from_params(params: &Value) -> Result<ActionType, String> {
    let action = sfield(params, "action_type")?;
    let target_folder = params.get("target_folder").and_then(|v| v.as_str()).map(String::from);
    let label = params.get("label").and_then(|v| v.as_str()).map(String::from);
    ActionType::from_request(&action, target_folder, label)
}

#[cfg(test)]
mod reply_list_tests {
    use super::parse_reply_list;

    #[test]
    fn parses_json_fenced_and_lines() {
        assert_eq!(parse_reply_list(r#"["Yes", " Sure "]"#), vec!["Yes", "Sure"]);
        assert_eq!(parse_reply_list("```json\n[\"A\",\"B\"]\n```"), vec!["A", "B"]);
        assert_eq!(parse_reply_list("- One\n- \"Two\"\n\n* Three\n- Four"), vec!["One", "Two", "Three"]);
    }
}
