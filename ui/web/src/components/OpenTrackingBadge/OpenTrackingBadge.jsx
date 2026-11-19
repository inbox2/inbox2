// Open-tracking indicator for a sent message (docs/Open-Tracking.md): a compact
// "opened / not opened" pill next to the timestamp, click-to-expand into the full
// who/when/where history. Works for both backends:
//   - MX messages carry open_stats/opens inline from MessageSerializer.
//   - Local-channel messages (desktop) are fetched over the Tauri get_message_opens
//     command, which resolves the token embedded in the message body.
import { useCallback, useEffect, useRef, useState } from 'react';
import Icon from '../Icon';
import relativeTime from '../../lib/relativeTime';
import { isTauri } from '../../lib/tauri';
import log from '../../lib/log';
import useDismiss from '../../hooks/useDismiss';
import styles from './OpenTrackingBadge.module.css';

// A message was tracked if the serializer said so (MX) or its body still carries
// the pixel URL (local channels).
function isTracked(message) {
  if (message?.tracked === true) return true;
  const html = message?.body_html || message?.bodyHtml || '';
  return /\/o\/[A-Za-z0-9_-]+\.gif/.test(html);
}

function isOutbound(message) {
  return message?.is_inbound === false || message?.isInbound === false;
}

function summarize(opens) {
  const real = opens.filter((o) => !o.proxied);
  const last = real.reduce((m, o) => (o.opened_at > m ? o.opened_at : m), '');
  return { opened: real.length > 0, count: real.length, proxyHits: opens.length - real.length, last };
}

export default function OpenTrackingBadge({ message }) {
  const [opens, setOpens] = useState(() => message?.opens || null);
  const [open, setOpen] = useState(false);
  const ref = useRef(null);

  const tracked = isTracked(message) && isOutbound(message);
  const messageKey = message?.key || message?.id;

  // Local channels: fetch opens over Tauri (MX already has them inline).
  useEffect(() => {
    let cancelled = false;
    if (!tracked || Array.isArray(opens) || !isTauri() || !messageKey) return undefined;
    (async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core');
        const rows = await invoke('get_message_opens', { messageKey });
        if (!cancelled) setOpens(Array.isArray(rows) ? rows : []);
      } catch (e) {
        log.warn('OpenTracking', `opens fetch failed: ${e?.message || e}`);
        if (!cancelled) setOpens([]);
      }
    })();
    return () => { cancelled = true; };
  }, [tracked, opens, messageKey]);

  // Close the popover on an outside click or Escape.
  const close = useCallback(() => setOpen(false), []);
  useDismiss(ref, close, open);

  const toggle = useCallback((e) => { e.stopPropagation(); setOpen((v) => !v); }, []);

  if (!tracked) return null;

  const rows = Array.isArray(opens) ? opens : [];
  const { opened, count, proxyHits, last } = summarize(rows);
  const label = opened ? `Opened${count > 1 ? ` ${count}×` : ''}` : 'Not opened';

  return (
    <span className={styles.wrap} ref={ref}>
      <button
        type="button"
        className={[styles.pill, opened ? styles.on : ''].join(' ')}
        onClick={toggle}
        title={opened && last ? `Last opened ${relativeTime(new Date(last))}` : 'Open tracking'}
        aria-label={label}
      >
        <Icon name={opened ? 'eye.fill' : 'eye.slash'} size={12} />
        <span className={styles.label}>{label}</span>
      </button>

      {open && (
        <div className={styles.pop} role="presentation" onClick={(e) => e.stopPropagation()}>
          <div className={styles.popHead}>Open history</div>
          {rows.length === 0 && <div className={styles.empty}>No opens recorded yet.</div>}
          {rows.map((o, i) => (
            <div key={i} className={styles.row}>
              <span className={styles.when}>{o.opened_at ? relativeTime(new Date(o.opened_at)) : '—'}</span>
              <span className={styles.where}>
                {[o.geo_city, o.geo_country].filter(Boolean).join(', ') || o.ip || 'Unknown location'}
              </span>
              {o.proxied && (
                <span className={styles.proxy} title="A mail provider’s proxy fetched this, like Apple Mail Privacy or Gmail.">
                  {o.proxy_kind || 'proxy'}
                </span>
              )}
            </div>
          ))}
          {proxyHits > 0 && (
            <div className={styles.foot}>
              {proxyHits} proxy/prefetch {proxyHits === 1 ? 'hit' : 'hits'} excluded from the count.
            </div>
          )}
        </div>
      )}
    </span>
  );
}
