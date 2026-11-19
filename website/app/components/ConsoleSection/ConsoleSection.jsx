import Button from "../Button/Button.jsx";
import ConsoleShot from "./ConsoleShot.jsx";
import { CONSOLE_URL } from "../../lib/nav.js";
import styles from "./ConsoleSection.module.css";

const TABS = ["Home", "Domains", "People", "Routing rules", "Billing & plan", "API keys & devices", "Applications"];

const POINTS = [
  ["DNS checks every 5 minutes", "We check each domain's MX, SPF, DKIM and DMARC and give you the exact record to paste when one is missing."],
  ["Rules with a dry run", "Write a rule and see what it would have matched in your last 500 conversations before it goes live."],
  ["Keys and devices", "Each integration gets its own API key, and you can revoke any linked phone or desktop in one click."],
];

/** The real Console Home, rebuilt as a screenshot. */
export default function ConsoleSection() {
  return (
    <section className={styles.section}>
      <div className={`wrap ${styles.inner}`}>
        <div className={styles.head}>
          <div className={styles.headText}>
            <h2 className={styles.h2}>Run your domain from one console</h2>
            <p className="lede">The console holds domains, DNS health, people, routing rules, billing and API keys. See DNS faults before mail bounces.</p>
            <div className={styles.ctas}>
              <Button variant="offset" href={CONSOLE_URL}>Open the console</Button>
              <Button variant="glassink" to="/">See the apps</Button>
            </div>
          </div>
          <div className={styles.panelWrap}>
            <img className={styles.panel} src="/assets/3d/panel.webp" alt="A control panel with knobs and a status light" loading="lazy" />
          </div>
        </div>

        <div className={styles.stage}>
          <div className={styles.bleed} aria-hidden="true" />
          <div className={styles.chips}>
            {TABS.map((t, i) => <span key={t} className={i === 0 ? styles.chipOn : styles.chip}>{t}</span>)}
          </div>
          {/* A rebuilt screenshot, not a console: fake domains and figures,
              so it is hidden from assistive tech the same way it is on /. */}
          <div aria-hidden="true"><ConsoleShot /></div>
        </div>

        <div className={styles.points}>
          {POINTS.map(([t, b]) => (
            <div key={t}><b>{t}</b>{b}</div>
          ))}
        </div>
      </div>
    </section>
  );
}
