import { useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router';
import Icon from '../Icon';
import useTriage from '../../hooks/useTriage';
import { isTauri } from '../../lib/tauri';
import styles from './ActivityPanel.module.css';

/* Floating background-work panel (desktop only), bottom-right on every screen.
 *
 * Triage runs in the background over thousands of threads — re-filing after a
 * Space change, catching up a widened window — and the only readout used to be
 * Settings → Triage & sync. This panel follows you across tabs instead: it
 * appears while the worker has a backlog, shows what it's chewing through, and
 * fades out shortly after it's done. Collapsed state is remembered per device;
 * dismissing hides it until the next batch starts. */

const DONE_LINGER_MS = 6000;
const COLLAPSED_KEY = 'inbox2_activity_collapsed';

export default function ActivityPanel() {
  const navigate = useNavigate();
  const { progress } = useTriage();
  const [collapsed, setCollapsed] = useState(() => {
    try { return localStorage.getItem(COLLAPSED_KEY) === '1'; } catch { return false; }
  });
  // Dismissed for THIS batch only — a new backlog brings the panel back.
  const [dismissed, setDismissed] = useState(false);
  const [lingering, setLingering] = useState(false);
  const wasWorking = useRef(false);
  const fillRef = useRef(null);

  const pending = progress.pending || 0;
  const inWindow = progress.inWindow || 0;
  const done = progress.done || 0;
  const working = pending > 0;
  const pct = inWindow > 0 ? Math.min(100, Math.round((done / inWindow) * 100)) : 100;
  // Jev can't classify (rejected key, credits ran out): the queue is paused.
  // A failing summary lane (OpenAI quota, …) only degrades the summaries.
  const jevError = progress.jevError || (progress.jevStatus === 'unauthorized' ? 'TypeSafe rejected the Jev key' : null);
  const blocked = !!jevError;
  const summaryError = progress.summaryError;
  const warn = blocked || !!summaryError;

  // Keep it up briefly after the last job so the finish is visible, and reset
  // the dismissal when a fresh batch starts.
  useEffect(() => {
    if (working && !wasWorking.current) setDismissed(false);
    if (!working && wasWorking.current) {
      setLingering(true);
      const t = setTimeout(() => setLingering(false), DONE_LINGER_MS);
      wasWorking.current = working;
      return () => clearTimeout(t);
    }
    wasWorking.current = working;
    return undefined;
  }, [working]);

  // Width is dynamic — a CSS custom property, never an inline style (F1).
  useEffect(() => {
    fillRef.current?.style.setProperty('--progress', `${pct}%`);
  });

  const toggle = () => {
    setCollapsed((c) => {
      const next = !c;
      try { localStorage.setItem(COLLAPSED_KEY, next ? '1' : '0'); } catch { /* private mode */ }
      return next;
    });
  };

  if (!isTauri() || dismissed) return null;
  if (!working && !lingering && !warn) return null;

  const title = blocked ? 'Triage paused' : working ? 'Triaging mail' : summaryError ? 'Summaries failing' : 'Triage up to date';
  const detail = blocked
    ? jevError
    : working
      ? `${done.toLocaleString()} of ${inWindow.toLocaleString()} · ${pending.toLocaleString()} to go`
      : `${inWindow.toLocaleString()} conversations`;

  return (
    <aside
      className={`${styles.panel} ${collapsed ? styles.collapsed : ''}`}
      aria-live="polite"
      aria-label="Background activity"
    >
      <div className={styles.head}>
        <button
          className={styles.toggle}
          onClick={toggle}
          aria-expanded={!collapsed}
          title={collapsed ? 'Show background activity' : 'Hide details'}
        >
          <Icon
            name={warn ? 'exclamationmark.triangle' : working ? 'arrow.triangle.2.circlepath' : 'checkmark.circle.fill'}
            size={14}
            className={`${styles.icon} ${working && !warn ? styles.spinning : ''} ${warn ? styles.warn : ''}`}
          />
          <span className={styles.title}>{title}</span>
          {collapsed && working && <span className={styles.pct}>{pct}%</span>}
        </button>
        <button
          className={styles.iconBtn}
          onClick={() => navigate('/settings?tab=triage')}
          aria-label={warn ? 'Fix it in Triage settings' : 'Triage settings'}
          title={warn ? 'Fix it in Triage settings' : 'Triage settings'}
        >
          <Icon name="gearshape" size={13} />
        </button>
        <button className={styles.iconBtn} onClick={() => setDismissed(true)} aria-label="Hide" title="Hide">
          <Icon name="xmark" size={12} />
        </button>
      </div>

      {!collapsed && (
        <>
          <div className={styles.bar}>
            <div ref={fillRef} className={`${styles.fill} ${blocked ? styles.fillBlocked : ''}`} />
          </div>
          <div className={styles.meta}>
            <span className={styles.detail} title={detail}>{detail}</span>
            {progress.currentDate && working && (
              <span className={styles.date}>{progress.currentDate.slice(0, 10)}</span>
            )}
          </div>
          {summaryError && (
            <div className={styles.error} title={summaryError}>
              Summaries: {summaryError}
            </div>
          )}
        </>
      )}
    </aside>
  );
}
