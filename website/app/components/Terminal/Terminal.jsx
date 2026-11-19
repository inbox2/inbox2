import { useState } from "react";
import Glyph from "../Glyph/Glyph.jsx";
import WindowFrame from "../WindowFrame/WindowFrame.jsx";
import { OsIcon } from "../OsIcons/OsIcons.jsx";
import { useReveal } from "../../lib/reveal.js";
import { shotSrc, useShotTheme } from "../../lib/shotTheme.jsx";
import { CLI_RELEASE, CLI_RELEASE_PAGE } from "../../lib/nav.js";
import styles from "./Terminal.module.css";

const POINTS = [
  ["inbox", "The same folders, Spaces, triage labels and provider labels as the desktop, over the same local database file"],
  ["keyboard", "Every action is a key: j/k to move, x to select, e to archive, v to move, / to search, ? for the full map"],
  ["search", "Use the same search operators as the desktop: from:, is:unread, has:attachment, larger:5mb, in:archive"],
  ["calendar", "Month, week, day and agenda views, with invites answered from the thread they arrived in"],
  ["update", "Drafts save to your provider's Drafts folder, attachments go by file path, and the Outbox shows what is still queued"],
  ["shield", "One sync engine: when the desktop app is open the terminal attaches to it, so nothing polls your accounts twice"],
  ["console", "Scriptable: inbox2 list, search, read and send work without the UI, with --json for pipes, cron jobs and agents"],
];

const SHOTS = [
  ["t-inbox", "The unified inbox in the terminal client, with Spaces, triage labels and a thread open"],
  ["t-compose", "Replying from the terminal, with the account picker and an attachment by path"],
  ["t-calendar", "The week view of the calendar in the terminal client"],
  ["t-scripting", "inbox2 list, search and send run as plain commands, with JSON output for scripts"],
];

/** The CLI section: the install lines, what it shares with the desktop, and a
 *  gallery of shots over fictional mail (ui/cli/tools/shots.py) — one large,
 *  the rest as thumbnails that swap it in. The shots follow the site's
 *  dark/light switch like every other. */
export default function Terminal() {
  const reveal = useReveal();
  const { theme } = useShotTheme();
  const [selected, setSelected] = useState(0);
  const [shot, alt] = SHOTS[selected];
  return (
    <section id="terminal" className={`${styles.section} on-dark`}>
      <div className={`wrap ${styles.head}`}>
        <div className={styles.headText}>
          <span className="kicker kicker--accent">CLI</span>
          <h2 className={styles.h2}>inbox2 in the terminal</h2>
          <p className="lede">Read and send mail from the terminal. An account you connect in the desktop app is ready here too.</p>
          <div className={styles.badges}>
            <span><OsIcon id="cli" />macOS and Linux terminals</span>
            <span><OsIcon id="macos" />Pairs with the desktop app</span>
          </div>
        </div>
        <div ref={reveal} className={`reveal ${styles.install}`} aria-label="Install the CLI">
          <p className={styles.installTitle}>Install</p>
          <pre className={styles.code}><code>{`curl -L ${CLI_RELEASE}/inbox2-cli-$(uname -s | tr A-Z a-z)-$(uname -m).tar.gz | tar xz
./inbox2/inbox2`}</code></pre>
          <p className={styles.installNote}>One file per platform, built by GitHub Actions from <code>main</code>, with the sync engine inside. macOS on Apple silicon and Intel, Linux on x86_64 and arm64. Connect an account in the desktop app first; the CLI reuses it. <a href={CLI_RELEASE_PAGE} target="_blank" rel="noopener">All builds and the wheel</a>.</p>
        </div>
      </div>

      <ul className={`wrap ${styles.points}`}>
        {POINTS.map(([g, p]) => <li key={p}><Glyph id={g} />{p}</li>)}
      </ul>

      <div className={`wrap ${styles.shots}`}>
        {/* key: a new frame per shot so the reveal runs again on swap */}
        <WindowFrame key={shot} src={`/assets/shots/${shot}.webp`} alt={alt} bare className={styles.lead} />
        <div className={styles.thumbs} role="tablist" aria-label="Screens of the CLI">
          {SHOTS.map(([id, label], i) => (
            <button
              key={id}
              type="button"
              role="tab"
              aria-selected={i === selected}
              className={styles.thumb}
              onClick={() => setSelected(i)}
            >
              <img src={shotSrc(`/assets/shots/${id}.webp`, theme)} alt={label} loading="lazy" />
            </button>
          ))}
        </div>
      </div>
    </section>
  );
}
