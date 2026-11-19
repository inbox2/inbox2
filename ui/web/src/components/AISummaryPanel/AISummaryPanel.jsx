import { useEffect, useReducer } from 'react';
import DOMPurify from 'dompurify';
import { summarizeThread } from '../../lib/ai';
import { persistConversationSummary } from '../../lib/localData';
import log from '../../lib/log';
import Spinner from '../Spinner';
import styles from './AISummaryPanel.module.css';

// Cache results keyed by `${conversationId}:${lastMsgKey}`: undefined = not
// attempted, null = failed, string = summary. Keying on the latest message
// means a thread that gains a new message regenerates rather than serving a
// stale summary. Lets re-selecting a thread render instantly and avoids
// re-running the model on a known failure.
const summaryCache = new Map();

/** Minimal markdown → HTML: bold, bullet points, line breaks. */
function renderMarkdown(text) {
  const html = text
    .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
    .replace(/^\*\s+/gm, '&bull; ')
    .replace(/^-\s+/gm, '&bull; ')
    .replace(/\n/g, '<br/>');
  return DOMPurify.sanitize(html);
}

/**
 * PREVIEW panel: always an AI-generated thread summary. When the model can't
 * produce one we show "Couldn’t write a summary." and log the reason — the
 * raw body text is intentionally not shown here.
 *
 * @param {Object} props
 * @param {string} props.conversationId
 * @param {string} props.threadText
 * @param {Array} [props.messages] - Thread messages; the last one's key keys the cache.
 * @param {string} [props.cachedSummary] - Summary persisted in SQLite, if any.
 * @param {string} [props.cachedSummaryKey] - Message key the persisted summary was generated for.
 * @param {(title: string) => void} [props.onTitleChange]
 */
export default function AISummaryPanel({
  conversationId,
  threadText,
  messages,
  cachedSummary,
  cachedSummaryKey,
  onTitleChange,
}) {
  const [, tick] = useReducer((x) => x + 1, 0);

  useEffect(() => {
    onTitleChange?.('Summary');
  }, [onTitleChange]);

  const hasThread = Boolean(conversationId && threadText);
  const lastMsgKey = messages?.[messages.length - 1]?.id ?? null;
  const cacheKey = `${conversationId}:${lastMsgKey}`;

  // Seed the in-memory cache from the SQLite-persisted summary, but only if it
  // was generated for the thread's current latest message (otherwise stale).
  if (hasThread && cachedSummary && cachedSummaryKey === lastMsgKey && !summaryCache.has(cacheKey)) {
    summaryCache.set(cacheKey, cachedSummary);
  }

  useEffect(() => {
    if (!hasThread) return undefined;
    if (summaryCache.has(cacheKey)) return undefined;

    let aborted = false;
    (async () => {
      const { summary, reason } = await summarizeThread(threadText);
      if (aborted) return;
      summaryCache.set(cacheKey, summary || null);
      if (!summary) {
        log.warn('AISummary', `Could not summarize ${conversationId}: ${reason}`);
      } else {
        // Persist so we never re-run the local model for this thread state.
        persistConversationSummary(conversationId, summary, lastMsgKey);
      }
      tick();
    })();

    return () => { aborted = true; };
  }, [conversationId, threadText, hasThread, cacheKey, lastMsgKey]);

  if (!hasThread) {
    return <p className={styles.unavailable}>Couldn’t write a summary.</p>;
  }

  if (summaryCache.has(cacheKey)) {
    const cached = summaryCache.get(cacheKey);
    if (cached) {
      return <div className={styles.text} dangerouslySetInnerHTML={{ __html: renderMarkdown(cached) }} />;
    }
    return <p className={styles.unavailable}>Couldn’t write a summary.</p>;
  }

  return (
    <div className={styles.loading}>
      <Spinner size={10} />
      <span className={styles.loadingText}>Analyzing</span>
    </div>
  );
}
