import { useEffect, useRef } from 'react';
import Icon from '../../components/Icon';
import JevKeyCard from './JevKeyCard';
import TriageLabelsEditor from '../../components/TriageLabelsEditor/TriageLabelsEditor';
import useTriage from '../../hooks/useTriage';
import useTriageLabels, { LOCAL_TRIAGE_LABELS } from '../../hooks/useTriageLabels';
import settingsStyles from './settings.module.css';
import styles from './TriageSyncSettings.module.css';

// Slider stops, narrowest first — the core's ProcessingWindow values.
const WINDOWS = [
  { value: 'new_only', label: '0d', long: 'new mail only' },
  { value: '1_month', label: '30d (default)', long: 'the last 30 days' },
  { value: '3_months', label: '90d', long: 'the last 90 days' },
  { value: '6_months', label: '180d', long: 'the last 180 days' },
  { value: '1_year', label: '360d', long: 'the last 360 days' },
  { value: 'everything', label: 'Everything', long: 'all mail' },
];

/**
 * Settings → "Triage & sync": progress of the background classifier/summarizer,
 * the processing-window selector and the local-channel label list. Backed by
 * the Tauri commands get/set_processing_window + triage_progress (and the
 * triage-progress event) and get/set_triage_labels.
 */
export default function TriageSyncSettings() {
  const { progress, window, setWindow, spaceClassify, setSpaceClassify } = useTriage();
  const { labels, create, update, remove } = useTriageLabels(LOCAL_TRIAGE_LABELS);
  const inWindow = progress.inWindow || 0;
  const done = progress.done || 0;
  const pct = inWindow > 0 ? Math.min(100, Math.round((done / inWindow) * 100)) : 100;
  const active = (progress.pending || 0) > 0;
  const windowIndex = Math.max(0, WINDOWS.findIndex((w) => w.value === window));

  // Width is a dynamic value — set via a CSS custom property (no inline styles).
  const fillRef = useRef(null);
  useEffect(() => {
    if (fillRef.current) fillRef.current.style.setProperty('--progress', `${pct}%`);
  }, [pct]);

  return (
    <div className={settingsStyles.prefGrid}>
      {/* Left: the model key, progress, range and Spaces — right: the labels. */}
      <section className={settingsStyles.settingsPanel}>
      <h1 className={settingsStyles.settingsTitle}>Triage &amp; sync</h1>

      <div className={styles.sectionLabel}>Triage model</div>
      <JevKeyCard />

      <div className={styles.sectionLabel}>Processing progress</div>
      <div className={styles.card}>
        <div className={styles.bar}>
          <div ref={fillRef} className={styles.fill} />
        </div>
        <div className={styles.statusRow}>
          <span className={active ? styles.working : styles.upToDate}>
            {active ? 'Working…' : 'Up to date'}
          </span>
          <span className={styles.count}>{done} / {inWindow}</span>
        </div>
      </div>

      <div className={styles.sectionLabel}>How far back to process</div>
      <div className={`${styles.card} ${styles.windowCard}`}>
        {/* Native range input — 5 stops, themed with accent-color. */}
        <input
          type="range"
          className={styles.windowSlider}
          min={0}
          max={WINDOWS.length - 1}
          step={1}
          value={windowIndex}
          onChange={(e) => setWindow(WINDOWS[Number(e.target.value)].value)}
          aria-label="How far back to process"
          aria-valuetext={WINDOWS[windowIndex].long}
        />
        <div className={styles.windowTicks} aria-hidden="true">
          {WINDOWS.map((w, i) => (
            <span
              key={w.value}
              className={`${styles.windowTick} ${i === windowIndex ? styles.windowTickActive : ''}`}
            >
              {w.label}
            </span>
          ))}
        </div>
      </div>

      <p className={styles.note}>
        {window === 'new_only'
          ? `Triage covers new mail only (${inWindow.toLocaleString()} so far).`
          : `Triage covers ${WINDOWS[windowIndex].long}: ${inWindow.toLocaleString()} conversations.`}
        {' '}Jev sorts the newest first. A wider range sorts older mail too, without downloading it again.
      </p>

      <div className={styles.sectionLabel}>Org spaces</div>
      <div className={styles.card}>
        <button
          className={styles.option}
          onClick={() => setSpaceClassify(!spaceClassify)}
          role="switch"
          aria-checked={spaceClassify}
        >
          <span>Sort into your org&rsquo;s Spaces</span>
          {spaceClassify && <Icon name="checkmark" size={14} className={styles.check} />}
        </button>
      </div>
      <p className={styles.note}>
        Sorts your own accounts&rsquo; mail into your org&rsquo;s Spaces. Only you see it there.
        You need a Jev key (above).
      </p>
      </section>

      <section className={`${settingsStyles.settingsPanel} ${styles.labelsPanel}`}>
      <h1 className={settingsStyles.settingsTitle}>Labels</h1>
      <p className={styles.note}>
        Jev puts one of these on every thread in your connected accounts. Describe what
        each label is for, and what it isn&rsquo;t, in plain words.
      </p>
      <div className={styles.labels}>
        <TriageLabelsEditor labels={labels} onCreate={create} onUpdate={update} onRemove={remove} />
      </div>
      </section>
    </div>
  );
}
