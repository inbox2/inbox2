// React hook for AI classification of email messages.
// Runs inference asynchronously and caches results per message ID.
// Never blocks rendering — returns null until results are ready.
// When running in Tauri, persists results to local SQLite and
// seeds the in-memory cache from stored columns on first access.

import { getDb } from '../db.js';
import { useState, useEffect, useMemo, useRef } from 'react';
import { isInferenceReady, analyzeSentiment, classifyIntent } from './inference';
import { isTauri } from '../tauri';
import { isDemoMode } from '../demoData';

// In-memory cache for classification results (survives re-renders, clears on page reload)
const cache = new Map();

/**
 * Persist classification results to local SQLite (Tauri only).
 * Fire-and-forget — errors are silently ignored.
 */
async function persistToSQLite(messageId, sentiment, intent) {
  if (!isTauri()) return;
  // Inferred from scrubbed text while demo mode is on — never write that onto
  // the real message row (see persistConversationSummary for the same rule).
  if (isDemoMode()) return;
  try {
    const db = await getDb();
    await db.execute(
      `UPDATE messages SET sentiment_label = ?, sentiment_score = ?, intent_label = ?, intent_score = ? WHERE key = ?`,
      [
        sentiment?.label || null,
        sentiment?.score || null,
        intent?.label || null,
        intent?.score || null,
        messageId,
      ]
    );
  } catch {
    // Non-critical — in-memory cache still works
  }
}

/**
 * Seed the in-memory cache from a message object that may carry
 * persisted sentiment/intent from SQLite (set by localData.mapMessage).
 */
export function seedCache(messageId, message) {
  if (!messageId || cache.has(messageId)) return;
  if (!message?.sentiment && !message?.intent) return;
  cache.set(messageId, {
    sentiment: message.sentiment || null,
    intent: message.intent || null,
  });
}

/**
 * @typedef {Object} AIClassification
 * @property {{label: string, score: number} | null} sentiment
 * @property {{label: string, score: number} | null} intent
 * @property {boolean} loading
 */

/**
 * Hook that returns AI classification for a message.
 * Returns cached result immediately if available, otherwise triggers async inference.
 *
 * @param {string|null} messageId - Unique message identifier for caching
 * @param {string|null} text - Plain text content to classify
 * @param {Object|null} [message] - Message object (may contain persisted sentiment/intent)
 * @returns {AIClassification}
 */
export function useAIClassification(messageId, text, message) {
  // Seed cache from persisted DB columns if available
  if (message) {
    seedCache(messageId, message);
  }

  // Derive initial/cached state synchronously from the cache — no refs needed
  const initial = useMemo(() => {
    const cached = messageId ? cache.get(messageId) : null;
    return cached
      ? { sentiment: cached.sentiment, intent: cached.intent, loading: false }
      : { sentiment: null, intent: null, loading: false };
  }, [messageId]);

  const [inferred, setInferred] = useState(null);
  const runningRef = useRef(null);

  // Reset inferred state when messageId changes
  const prevId = useRef(messageId);
  useEffect(() => {
    if (prevId.current !== messageId) {
      prevId.current = messageId;
      setInferred(null);
    }
  }, [messageId]);

  useEffect(() => {
    if (!messageId || !text) return;
    // isInferenceReady() already means a usable engine exists. Don't gate on
    // hasAIConsent()/allModelsReady() — those track the browser Transformers
    // models and are never set for the Apple Intelligence or native-ONNX
    // engines, which is why desktop sentiment/intent never ran. The browser
    // path only flips isInferenceReady() true after consent + models anyway.
    if (!isInferenceReady()) return;
    if (cache.has(messageId)) return;
    if (runningRef.current === messageId) return;

    let cancelled = false;
    runningRef.current = messageId;
    setInferred({ sentiment: null, intent: null, loading: true });

    (async () => {
      try {
        const [sentiment, intent] = await Promise.all([
          analyzeSentiment(text),
          classifyIntent(text),
        ]);

        if (cancelled) return;

        const data = { sentiment, intent };
        cache.set(messageId, data);
        setInferred({ ...data, loading: false });

        // Persist to SQLite in the background
        persistToSQLite(messageId, sentiment, intent);
      } catch {
        if (!cancelled) {
          setInferred({ sentiment: null, intent: null, loading: false });
        }
      } finally {
        if (!cancelled) runningRef.current = null;
      }
    })();

    return () => { cancelled = true; };
  }, [messageId, text]);

  return inferred || initial;
}
