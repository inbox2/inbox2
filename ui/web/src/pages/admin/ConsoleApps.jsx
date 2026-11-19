import { useState, useEffect } from 'react';
import api from '../../lib/api';
import log from '../../lib/log';
import Icon from '../../components/Icon';
import { openLink } from '../../lib/openLink';
import { AppleMark, PlayMark, WindowsMark, LinuxMark } from '../../components/StoreBadges/StoreBadges';
import c from './console.module.css';
import styles from './ConsoleApps.module.css';

const CLI_RELEASE_PAGE = 'https://github.com/inbox2/inbox2/releases/tag/cli-latest';

const OS = {
  macos: { name: 'macOS', mark: (s) => <AppleMark size={s} gradientId={`appleMac${s}`} /> },
  windows: { name: 'Windows', mark: (s) => <WindowsMark size={s} /> },
  linux: { name: 'Linux', mark: (s) => <LinuxMark size={s} /> },
};

// The visitor's OS, so the big button is the one they want. Falls back to macOS.
function detectOs() {
  const p = (navigator.userAgentData?.platform || navigator.platform || navigator.userAgent).toLowerCase();
  if (p.includes('win')) return 'windows';
  // Android reports a Linux platform string; only its user agent says Android.
  if (p.includes('linux') && !p.includes('android') && !/android/i.test(navigator.userAgent)) return 'linux';
  return 'macos';
}

const mb = (bytes) => (bytes ? `${Math.round(bytes / 1048576)} MB` : null);

function external(e) {
  e.preventDefault();
  openLink(e.currentTarget.href, { forceExternal: true });
}

/* Get-the-apps view: desktop up front (data-driven from the latest published
 * release, the visitor's OS as the primary button), then mobile and terminal. */
export default function ConsoleApps() {
  const [release, setRelease] = useState(null);

  useEffect(() => {
    let active = true;
    api.get('/desktop/releases/latest')
      .then((data) => { if (active) setRelease(data); })
      .catch((err) => { log.info('console', 'no desktop release available', err); });
    return () => { active = false; };
  }, []);

  const mine = detectOs();
  const downloads = release?.downloads || [];
  const primary = downloads.find((d) => d.os === mine) || downloads[0];
  const others = downloads.filter((d) => d !== primary);
  const primaryOs = OS[primary?.os || mine];

  return (
    <div className={styles.colored}>
      <div className={c.pageHead}>
        <div>
          <div className={c.pageEyebrow}>Downloads</div>
          <h1 className={c.pageTitle}>Get the apps</h1>
          <p className={c.pageSub}>
            Free on desktop, iPhone, Android and the terminal. Your mail lives in a local file on your
            device, so it opens fast and works without a connection.
          </p>
        </div>
      </div>

      <section className={`${c.card} ${styles.hero}`}>
        <div className={styles.heroText}>
          <span className={styles.kicker}><Icon name="sparkles" size={13} /> Desktop app</span>
          <h2 className={styles.heroTitle}>inbox2 for {primaryOs.name}</h2>
          <ul className={styles.points}>
            <li><Icon name="checkmark.circle.fill" size={15} /> Every mailbox in one window, offline</li>
            <li><Icon name="checkmark.circle.fill" size={15} /> Keyboard-first, with native notifications</li>
            <li><Icon name="checkmark.circle.fill" size={15} /> Updates itself in the background</li>
          </ul>
          {primary ? (
            <a className={styles.primaryBtn} href={primary.url} download>
              <span className={styles.primaryMark}>{primaryOs.mark(22)}</span>
              <span className={styles.btnText}>
                <span className={styles.btnMain}>Download for {primary.label}</span>
                <span className={styles.btnSub}>{[`v${release.version}`, mb(primary.size)].filter(Boolean).join(' · ')}</span>
              </span>
              <Icon name="arrow.down" size={16} />
            </a>
          ) : (
            <span className={`${styles.primaryBtn} ${styles.disabled}`} aria-disabled="true">
              <span className={styles.primaryMark}>{primaryOs.mark(22)}</span>
              <span className={styles.btnText}>
                <span className={styles.btnMain}>Download for {primaryOs.name}</span>
                <span className={styles.btnSub}>No build published yet</span>
              </span>
            </span>
          )}
          {others.length > 0 && (
            <div className={styles.others}>
              <span className={styles.othersLabel}>Also for</span>
              {others.map((d) => (
                <a key={d.filename || d.label} className={styles.chip} href={d.url} download>
                  {OS[d.os]?.mark(16)} {d.label}
                </a>
              ))}
            </div>
          )}
        </div>
        <div className={styles.heroShot}>
          <img src="/console/shots/triage-light.webp" alt="The inbox2 desktop app showing a triaged inbox" />
        </div>
      </section>

      <div className={styles.grid}>
        <section className={`${c.card} ${styles.tile}`}>
          <div className={styles.tileText}>
            <span className={styles.kicker}>iPhone + Android</span>
            <h2 className={styles.tileTitle}>Your inbox in your pocket</h2>
            <p className={styles.tileSub}>Push for new mail, swipe to triage, and a voice assistant that reads you the morning.</p>
            <div className={styles.stores}>
              <span className={styles.store} aria-disabled="true">
                <AppleMark size={20} gradientId="appleStore" /> App Store
              </span>
              <span className={styles.store} aria-disabled="true">
                <PlayMark size={18} /> Google Play
              </span>
            </div>
            <span className={styles.soon}>Coming soon to the stores</span>
          </div>
          <div className={styles.phone}>
            <img src="/console/shots/m-inbox-light.webp" alt="The inbox2 iPhone app" />
          </div>
        </section>

        <section className={`${c.card} ${styles.tile}`}>
          <div className={styles.tileText}>
            <span className={styles.kicker}><Icon name="terminal" size={13} /> Terminal</span>
            <h2 className={styles.tileTitle}>Mail without leaving the shell</h2>
            <p className={styles.tileSub}>A full keyboard client on the same local engine as the desktop app.</p>
            <a className={styles.secondaryBtn} href={CLI_RELEASE_PAGE} onClick={external}>
              Get the CLI <Icon name="arrow.up.right" size={13} />
            </a>
          </div>
          <div className={styles.termShot}>
            <img src="/console/shots/t-inbox-light.webp" alt="The inbox2 terminal client" />
          </div>
        </section>
      </div>
    </div>
  );
}
