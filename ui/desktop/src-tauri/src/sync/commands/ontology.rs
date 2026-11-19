//! Tauri commands for the local Lore ontology (docs/Ontology.md): the same JSON
//! shapes as the Rails `/lore/*` endpoints, read from the shared SQLite store.
//! Each read first catches the deterministic (headers) pass up, so a fresh
//! install shows entities before the background miner's first tick.

use serde_json::Value;
use tauri::State;

use super::SyncState;
use inbox2_core::ontology;

fn catch_up(sync: &SyncState) -> Result<std::sync::Arc<parking_lot::Mutex<rusqlite::Connection>>, String> {
    let conn = sync.engine.store().connection();
    ontology::mine_headers(&conn.lock()).map_err(|e| e.to_string())?;
    Ok(conn)
}

/// Remember what "Send to…" made for a Lore item (docs/plans/lore.md).
#[tauri::command]
pub fn lore_sent_add(sync: State<'_, SyncState>, item_key: String, connection_name: String, summary: String) -> Result<Value, String> {
    let row = sync.engine.store().add_lore_sent(&item_key, &connection_name, &summary).map_err(|e| e.to_string())?;
    serde_json::to_value(row).map_err(|e| e.to_string())
}

/// Every reference "Send to…" stored, newest first.
#[tauri::command]
pub fn lore_sent_list(sync: State<'_, SyncState>) -> Result<Value, String> {
    let rows = sync.engine.store().lore_sent().map_err(|e| e.to_string())?;
    serde_json::to_value(rows).map_err(|e| e.to_string())
}

/// `{ entities: [{ id, kind, name, email_domain, address, mention_count, last_seen_at }] }`
#[tauri::command]
pub fn lore_entities(sync: State<'_, SyncState>, kind: Option<String>, q: Option<String>) -> Result<Value, String> {
    let conn = catch_up(&sync)?;
    let c = conn.lock();
    ontology::entities(&c, kind.as_deref(), q.as_deref()).map_err(|e| e.to_string())
}

/// `{ entity: { …, facts: [...], conversations: [...] } }`; errors "not found" for an unknown id.
#[tauri::command]
pub fn lore_entity(sync: State<'_, SyncState>, id: String) -> Result<Value, String> {
    let conn = catch_up(&sync)?;
    let c = conn.lock();
    ontology::entity(&c, &id).map_err(|e| e.to_string())?.ok_or_else(|| "not found".to_string())
}

/// Hand edits to the local ontology (docs/Ontology.md "Editing"). The miner keeps them.
#[tauri::command]
pub fn lore_entity_rename(sync: State<'_, SyncState>, id: String, name: String) -> Result<(), String> {
    ontology::rename_entity(&sync.engine.store().connection().lock(), &id, &name)
}

#[tauri::command]
pub fn lore_entity_set_kind(sync: State<'_, SyncState>, id: String, kind: String) -> Result<(), String> {
    ontology::change_entity_kind(&sync.engine.store().connection().lock(), &id, &kind)
}

#[tauri::command]
pub fn lore_entity_merge(sync: State<'_, SyncState>, id: String, into: String) -> Result<(), String> {
    ontology::merge_entity(&sync.engine.store().connection().lock(), &id, &into)
}

#[tauri::command]
pub fn lore_entity_remove(sync: State<'_, SyncState>, id: String) -> Result<(), String> {
    ontology::remove_entity(&sync.engine.store().connection().lock(), &id)
}

#[tauri::command]
pub fn lore_fact_edit(sync: State<'_, SyncState>, fact_id: i64, name: Option<String>, value: Option<String>) -> Result<(), String> {
    ontology::edit_fact(&sync.engine.store().connection().lock(), fact_id, name.as_deref(), value.as_deref())
}

#[tauri::command]
pub fn lore_fact_remove(sync: State<'_, SyncState>, fact_id: i64) -> Result<(), String> {
    ontology::remove_fact(&sync.engine.store().connection().lock(), fact_id)
}

/// `{ nodes: [{ id, kind, name, email_domain, address, weight }], links: [{ source, target, label, weight }] }`
#[tauri::command]
pub fn lore_graph(sync: State<'_, SyncState>) -> Result<Value, String> {
    let conn = catch_up(&sync)?;
    let c = conn.lock();
    ontology::graph(&c).map_err(|e| e.to_string())
}
