// Link-click indicator for a sent message (docs/Open-Tracking.md): a compact
// pill next to the open indicator, click-to-expand into per-link click history
// (which link, by who, when, where). Domains-only (MX), so the data arrives
// inline on the message from MessageSerializer — no fetch.
import { useCallback, useRef, useState } from 'react';
import Icon from '../Icon';
import useDismiss from '../../hooks/useDismiss';
import relativeTime from '../../lib/relativeTime';
import styles from './OpenTrackingBadge.module.css';

function shortUrl(url) {
  try {
    const u = new URL(url);
    const path = (u.pathname + u.search).replace(/\/$/, '');
    return u.host + (path.length > 28 ? path.slice(0, 28) + '…' : path);
  } catch { return url; }
}

export default function LinkClicksBadge({ message }) {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);

  const close = useCallback(() => setOpen(false), []);
  useDismiss(ref, close, open);

  const toggle = useCallback((e) => { e.stopPropagation(); setOpen((v) => !v); }, []);

  const links = message?.links;
  const stats = message?.link_stats;
  if (!Array.isArray(links) || links.length === 0) return null;

  const count = stats?.click_count || 0;
  const clicked = count > 0;
  const label = clicked ? `${count} click${count > 1 ? 's' : ''}` : 'No clicks';

  return (
    <span className={styles.wrap} ref={ref}>
      <button
        type="button"
        className={[styles.pill, clicked ? styles.on : ''].join(' ')}
        onClick={toggle}
        title={`${links.length} tracked link${links.length > 1 ? 's' : ''}`}
        aria-label={label}
      >
        <Icon name="link" size={12} />
        <span className={styles.label}>{label}</span>
      </button>

      {open && (
        <div className={styles.pop} role="presentation" onClick={(e) => e.stopPropagation()}>
          <div className={styles.popHead}>Link clicks</div>
          {links.map((link, i) => (
            <div key={i} className={styles.linkGroup}>
              <div className={styles.linkUrl} title={link.url}>
                <span className={styles.linkHost}>{shortUrl(link.url)}</span>
                <span className={styles.linkCount}>{link.click_count || 0}</span>
              </div>
              {(link.clicks || []).map((c, j) => (
                <div key={j} className={styles.row}>
                  <span className={styles.when}>{c.clicked_at ? relativeTime(new Date(c.clicked_at)) : '—'}</span>
                  <span className={styles.where}>
                    {[c.geo_city, c.geo_country].filter(Boolean).join(', ') || c.ip || 'Unknown'}
                  </span>
                  {c.proxied && (
                    <span className={styles.proxy} title="A mail security scanner (SafeLinks, Mimecast…) opened this link.">
                      {c.proxy_kind || 'scan'}
                    </span>
                  )}
                </div>
              ))}
            </div>
          ))}
          {stats?.bot_hits > 0 && (
            <div className={styles.foot}>{stats.bot_hits} scanner {stats.bot_hits === 1 ? 'hit' : 'hits'} excluded from the count.</div>
          )}
        </div>
      )}
    </span>
  );
}
