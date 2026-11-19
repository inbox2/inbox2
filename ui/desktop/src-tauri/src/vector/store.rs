use inbox2_core::sync::model::EmbeddingStatus;
use inbox2_core::triage::ProcessingWindow;
use parking_lot::Mutex;
use rusqlite::{params, Connection};
use std::sync::Arc;

use crate::sync::error::Result;

/// Vector store operations on the shared SQLite database.
///
/// All vector data lives in the same inbox2.db as messages. Embeddings
/// are stored as little-endian f32 BLOBs for zero-copy cosine similarity.
pub struct VectorStore {
    conn: Arc<Mutex<Connection>>,
}

impl VectorStore {
    pub fn new(conn: Arc<Mutex<Connection>>) -> Self {
        Self { conn }
    }

    /// Store an embedding for a message chunk.
    pub fn store_embedding(
        &self,
        message_key: &str,
        chunk_index: usize,
        chunk_text_hash: &str,
        embedding: &[f32],
        model_id: &str,
    ) -> Result<()> {
        let conn = self.conn.lock();
        let now = chrono::Utc::now().to_rfc3339();
        let blob = f32_slice_to_blob(embedding);

        conn.execute(
            "INSERT INTO message_embeddings
             (message_key, chunk_index, chunk_text_hash, embedding, model_id, dimensions, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(message_key, chunk_index) DO UPDATE SET
               chunk_text_hash = excluded.chunk_text_hash,
               embedding = excluded.embedding,
               model_id = excluded.model_id,
               dimensions = excluded.dimensions,
               created_at = excluded.created_at",
            params![
                message_key,
                chunk_index as i32,
                chunk_text_hash,
                blob,
                model_id,
                embedding.len() as i32,
                now,
            ],
        )?;
        Ok(())
    }

    /// Check if a chunk with the same hash already has an embedding (skip re-embedding).
    pub fn has_embedding(&self, message_key: &str, chunk_index: usize, hash: &str) -> Result<bool> {
        let conn = self.conn.lock();
        let exists: bool = conn
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM message_embeddings
                 WHERE message_key = ?1 AND chunk_index = ?2 AND chunk_text_hash = ?3)",
                params![message_key, chunk_index as i32, hash],
                |row| row.get(0),
            )?;
        Ok(exists)
    }

    /// Delete all embeddings for a message (used on re-index or message deletion).
    pub fn delete_embeddings(&self, message_key: &str) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "DELETE FROM message_embeddings WHERE message_key = ?1",
            params![message_key],
        )?;
        Ok(())
    }

    /// Enqueue a message for background embedding.
    pub fn enqueue_for_embedding(&self, message_key: &str) -> Result<()> {
        let conn = self.conn.lock();
        let now = chrono::Utc::now().to_rfc3339();
        conn.execute(
            "INSERT OR IGNORE INTO embedding_queue (message_key, status, created_at, updated_at)
             VALUES (?1, ?4, ?2, ?3)",
            params![message_key, now, now, EmbeddingStatus::Pending.as_str()],
        )?;
        Ok(())
    }

    /// Get a batch of pending messages from the embedding queue.
    /// Earliest message date still inside the embedding window (RFC3339), or
    /// `None` for "everything" / a missing setting → embed all history. Bounds
    /// the *semantic* index only; keyword/FTS search covers everything regardless.
    fn embedding_cutoff(&self) -> Option<String> {
        let value: Option<String> = {
            let conn = self.conn.lock();
            conn.query_row(
                "SELECT value FROM vector_settings WHERE key = 'embedding_window'",
                [],
                |r| r.get(0),
            )
            .ok()
        };
        let window = value
            .as_deref()
            .and_then(ProcessingWindow::from_str)
            .unwrap_or(ProcessingWindow::OneYear);
        window.cutoff(chrono::Utc::now()).map(|dt| dt.to_rfc3339())
    }

    pub fn get_pending_embeddings(&self, limit: usize) -> Result<Vec<EmbeddingQueueItem>> {
        // Only embed mail inside the window. `m.created_at` is RFC3339 with a
        // fixed +00:00 offset (chrono), so a lexicographic compare against the
        // cutoff orders chronologically. NULL cutoff (Everything) embeds all.
        let cutoff = self.embedding_cutoff();
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT eq.message_key, m.from_address, m.subject, m.body_plain, m.body_html
             FROM embedding_queue eq
             JOIN messages m ON m.key = eq.message_key
             WHERE eq.status IN (?2, ?3) AND eq.attempts < 3
               AND (?4 IS NULL OR m.created_at >= ?4)
             ORDER BY eq.created_at ASC
             LIMIT ?1",
        )?;
        let rows = stmt.query_map(
            params![
                limit as i32,
                EmbeddingStatus::Pending.as_str(),
                EmbeddingStatus::Failed.as_str(),
                cutoff
            ],
            |row| {
            Ok(EmbeddingQueueItem {
                message_key: row.get(0)?,
                from_address: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                subject: row.get(2)?,
                body_plain: row.get(3)?,
                body_html: row.get(4)?,
            })
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    /// Drop queued (pending/failed) embedding work for mail outside the window —
    /// e.g. after a deep-archive sync enqueued the whole history before the
    /// window gate, or as the rolling window moves on. Stops the worker chewing
    /// through old mail and keeps the queue honest. Already-stored embeddings are
    /// left as-is. Returns how many rows were pruned. No-op for "everything".
    pub fn prune_out_of_window_pending(&self) -> Result<usize> {
        let Some(cutoff) = self.embedding_cutoff() else {
            return Ok(0);
        };
        let conn = self.conn.lock();
        let n = conn.execute(
            "DELETE FROM embedding_queue
             WHERE status IN (?1, ?2)
               AND message_key IN (SELECT key FROM messages WHERE created_at < ?3)",
            params![
                EmbeddingStatus::Pending.as_str(),
                EmbeddingStatus::Failed.as_str(),
                cutoff
            ],
        )?;
        Ok(n)
    }

    /// Mark a queue item as completed.
    pub fn mark_embedding_completed(&self, message_key: &str) -> Result<()> {
        let conn = self.conn.lock();
        let now = chrono::Utc::now().to_rfc3339();
        conn.execute(
            "UPDATE embedding_queue SET status = ?1, updated_at = ?2 WHERE message_key = ?3",
            params![EmbeddingStatus::Completed.as_str(), now, message_key],
        )?;
        Ok(())
    }

    /// Mark a queue item as failed.
    pub fn mark_embedding_failed(&self, message_key: &str, error: &str) -> Result<()> {
        let conn = self.conn.lock();
        let now = chrono::Utc::now().to_rfc3339();
        conn.execute(
            "UPDATE embedding_queue
             SET status = ?4, error_message = ?1, attempts = attempts + 1, updated_at = ?2
             WHERE message_key = ?3",
            params![error, now, message_key, EmbeddingStatus::Failed.as_str()],
        )?;
        Ok(())
    }

    /// Get vector statistics.
    pub fn stats(&self) -> Result<VectorStats> {
        let conn = self.conn.lock();
        let count = |sql: &str| -> Result<i64> {
            conn.query_row(sql, [], |row| row.get(0)).map_err(Into::into)
        };
        let count_status = |status: EmbeddingStatus| -> Result<i64> {
            conn.query_row(
                "SELECT COUNT(*) FROM embedding_queue WHERE status = ?1",
                params![status.as_str()],
                |row| row.get(0),
            )
            .map_err(Into::into)
        };
        Ok(VectorStats {
            total_embeddings: count("SELECT COUNT(*) FROM message_embeddings")?,
            total_messages_embedded: count(
                "SELECT COUNT(DISTINCT message_key) FROM message_embeddings",
            )?,
            queue_pending: count_status(EmbeddingStatus::Pending)?,
            queue_failed: count_status(EmbeddingStatus::Failed)?,
            queue_completed: count_status(EmbeddingStatus::Completed)?,
        })
    }

    /// Re-queue all messages for embedding (model change or reindex).
    pub fn reindex_all(&self) -> Result<usize> {
        let conn = self.conn.lock();
        let now = chrono::Utc::now().to_rfc3339();

        // Clear existing embeddings
        conn.execute("DELETE FROM message_embeddings", [])?;

        // Re-queue all messages
        let count = conn.execute(
            "INSERT OR REPLACE INTO embedding_queue (message_key, status, attempts, created_at, updated_at)
             SELECT key, ?2, 0, ?1, ?1 FROM messages",
            params![now, EmbeddingStatus::Pending.as_str()],
        )?;
        Ok(count)
    }

    /// Get or set a vector setting.
    pub fn get_setting(&self, key: &str) -> Result<Option<String>> {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT value FROM vector_settings WHERE key = ?1",
            params![key],
            |row| row.get(0),
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn set_setting(&self, key: &str, value: &str) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "INSERT OR REPLACE INTO vector_settings (key, value) VALUES (?1, ?2)",
            params![key, value],
        )?;
        Ok(())
    }

    /// Populate FTS5 index for a message (called after insert into messages).
    pub fn index_message_fts(&self, message_id: i64) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "INSERT INTO messages_fts(rowid, subject, body_plain, from_address, to_address)
             SELECT id, subject, body_plain, from_address, to_address
             FROM messages WHERE id = ?1",
            params![message_id],
        )?;
        Ok(())
    }
}

use rusqlite::OptionalExtension;

/// Item from the embedding queue with message content for chunking.
#[derive(Debug)]
pub struct EmbeddingQueueItem {
    pub message_key: String,
    pub from_address: String,
    pub subject: Option<String>,
    pub body_plain: Option<String>,
    pub body_html: Option<String>,
}

/// Vector subsystem statistics.
#[derive(Debug, serde::Serialize)]
pub struct VectorStats {
    pub total_embeddings: i64,
    pub total_messages_embedded: i64,
    pub queue_pending: i64,
    pub queue_failed: i64,
    pub queue_completed: i64,
}

/// Convert f32 slice to little-endian byte blob for SQLite storage.
pub fn f32_slice_to_blob(floats: &[f32]) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(floats.len() * 4);
    for f in floats {
        bytes.extend_from_slice(&f.to_le_bytes());
    }
    bytes
}

/// Convert a byte blob back to f32 slice.
pub fn blob_to_f32_vec(blob: &[u8]) -> Vec<f32> {
    blob.chunks_exact(4)
        .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blob_roundtrip() {
        let original = vec![1.0f32, -0.5, 0.0, 3.14159];
        let blob = f32_slice_to_blob(&original);
        let recovered = blob_to_f32_vec(&blob);
        assert_eq!(original, recovered);
    }
}
