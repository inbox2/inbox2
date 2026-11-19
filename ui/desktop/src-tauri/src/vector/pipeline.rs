use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;

use crate::ai::inference::AIInferenceEngine;
use crate::vector::chunker;
use crate::vector::embedder::Embedder;
use crate::vector::store::VectorStore;

/// Background embedding pipeline.
///
/// Polls the embedding queue every 5 seconds, processes pending messages
/// in batches, and stores the resulting vectors. Runs as a long-lived
/// tokio task alongside the sync engine.
pub struct EmbeddingPipeline {
    vector_store: Arc<VectorStore>,
    embedder: Arc<Embedder>,
    batch_size: usize,
}

impl EmbeddingPipeline {
    pub fn new(
        vector_store: Arc<VectorStore>,
        engine: Arc<Mutex<AIInferenceEngine>>,
        batch_size: usize,
    ) -> Self {
        Self {
            vector_store,
            embedder: Arc::new(Embedder::new(engine)),
            batch_size,
        }
    }

    /// Run the embedding pipeline loop. Call via `tokio::spawn`.
    pub async fn run(&self) {
        log::info!("Embedding pipeline started (batch_size={})", self.batch_size);
        // Clear any out-of-window backlog left by a deep-archive sync that
        // enqueued the whole history before the embedding window was enforced —
        // otherwise the worker would grind through years of old mail on boot.
        match self.vector_store.prune_out_of_window_pending() {
            Ok(n) if n > 0 => log::info!("Embedding pipeline: pruned {n} out-of-window queued message(s)"),
            Err(e) => log::warn!("Embedding pipeline: prune failed: {e}"),
            _ => {}
        }
        loop {
            // Check if embedding is enabled
            let enabled = self
                .vector_store
                .get_setting("embedding_enabled")
                .ok()
                .flatten()
                .map(|v| v == "true")
                .unwrap_or(true);

            if enabled && self.embedder.is_ready().await {
                if let Err(e) = self.process_batch().await {
                    log::warn!("Embedding pipeline batch error: {e}");
                }
            }

            tokio::time::sleep(Duration::from_secs(5)).await;
        }
    }

    async fn process_batch(&self) -> Result<(), String> {
        let items = self
            .vector_store
            .get_pending_embeddings(self.batch_size)
            .map_err(|e| e.to_string())?;

        if items.is_empty() {
            return Ok(());
        }

        log::debug!("Embedding pipeline: processing {} messages", items.len());

        for item in &items {
            match self.process_message(item).await {
                Ok(chunk_count) => {
                    self.vector_store
                        .mark_embedding_completed(&item.message_key)
                        .map_err(|e| e.to_string())?;
                    log::debug!(
                        "Embedded message {} ({} chunks)",
                        item.message_key,
                        chunk_count
                    );
                }
                Err(e) => {
                    log::warn!("Failed to embed message {}: {e}", item.message_key);
                    self.vector_store
                        .mark_embedding_failed(&item.message_key, &e)
                        .map_err(|e| e.to_string())?;
                }
            }
        }

        Ok(())
    }

    async fn process_message(
        &self,
        item: &crate::vector::store::EmbeddingQueueItem,
    ) -> Result<usize, String> {
        let chunks = chunker::chunk_message(
            &item.from_address,
            item.subject.as_deref(),
            item.body_plain.as_deref(),
            item.body_html.as_deref(),
        );

        if chunks.is_empty() {
            return Ok(0);
        }

        for chunk in &chunks {
            // Skip if already embedded with same content hash
            let already_done = self
                .vector_store
                .has_embedding(&item.message_key, chunk.chunk_index, &chunk.text_hash)
                .map_err(|e| e.to_string())?;
            if already_done {
                continue;
            }

            let embedding = self.embedder.embed(&chunk.text).await?;

            self.vector_store
                .store_embedding(
                    &item.message_key,
                    chunk.chunk_index,
                    &chunk.text_hash,
                    &embedding,
                    "all-MiniLM-L6-v2",
                )
                .map_err(|e| e.to_string())?;
        }

        Ok(chunks.len())
    }
}
