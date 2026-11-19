use std::sync::Arc;
use tauri::State;
use tokio::sync::Mutex;

use crate::ai::inference::AIInferenceEngine;
use crate::vector::search::{self, SearchResult};
use crate::vector::store::{VectorStats, VectorStore};

/// Tauri-managed state for the vector subsystem.
pub struct VectorState {
    pub store: Arc<VectorStore>,
    pub engine: Arc<Mutex<AIInferenceEngine>>,
    pub db_conn: Arc<parking_lot::Mutex<rusqlite::Connection>>,
}

/// The desktop's vector state, for the engine bus (sync/rpc.rs) — set only when
/// the desktop app runs (the embedding models load there, not in engine_daemon).
pub static HOSTED: std::sync::OnceLock<VectorState> = std::sync::OnceLock::new();

/// Semantic search over email embeddings.
#[tauri::command]
pub async fn vector_search(
    state: State<'_, VectorState>,
    query: String,
    limit: Option<usize>,
    account_key: Option<String>,
) -> Result<Vec<SearchResult>, String> {
    search_on(&state, query, limit, account_key).await
}

pub async fn search_on(
    state: &VectorState,
    query: String,
    limit: Option<usize>,
    account_key: Option<String>,
) -> Result<Vec<SearchResult>, String> {
    let limit = limit.unwrap_or(20);

    // Embed the query text
    let query_embedding = {
        let mut engine = state.engine.lock().await;
        if !engine.is_ready() {
            // Load on first use: the models may be on disk but not warmed yet.
            let _ = engine.warmup();
        }
        if !engine.is_ready() {
            return Err("AI engine not ready — models not loaded".to_string());
        }
        engine.run_embedding(&query)?.embedding
    };

    // Run hybrid search (keyword + semantic)
    search::hybrid_search(
        &state.db_conn,
        &query,
        &query_embedding,
        limit,
        0.6, // 60% semantic, 40% keyword
        account_key.as_deref(),
    )
    .map_err(|e| e.to_string())
}

/// Find messages similar to a given message.
#[tauri::command]
pub async fn vector_search_similar(
    state: State<'_, VectorState>,
    message_key: String,
    limit: Option<usize>,
) -> Result<Vec<SearchResult>, String> {
    search::search_similar(&state.db_conn, &message_key, limit.unwrap_or(10))
        .map_err(|e| e.to_string())
}

/// Get vector subsystem statistics.
#[tauri::command]
pub async fn vector_stats(state: State<'_, VectorState>) -> Result<VectorStats, String> {
    state.store.stats().map_err(|e| e.to_string())
}

/// Re-embed all messages (after model change or manual reindex).
#[tauri::command]
pub async fn vector_reindex(state: State<'_, VectorState>) -> Result<usize, String> {
    state.store.reindex_all().map_err(|e| e.to_string())
}

/// Get a vector setting.
#[tauri::command]
pub async fn get_vector_setting(
    state: State<'_, VectorState>,
    key: String,
) -> Result<Option<String>, String> {
    state.store.get_setting(&key).map_err(|e| e.to_string())
}

/// Set a vector setting.
#[tauri::command]
pub async fn set_vector_setting(
    state: State<'_, VectorState>,
    key: String,
    value: String,
) -> Result<(), String> {
    state
        .store
        .set_setting(&key, &value)
        .map_err(|e| e.to_string())
}
