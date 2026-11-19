import { Link } from "react-router";
import Button from "../components/Button/Button.jsx";
import DownloadButton from "../components/DownloadButton/DownloadButton.jsx";
import WindowFrame from "../components/WindowFrame/WindowFrame.jsx";
import HeroBuild from "../components/HeroBuild/HeroBuild.jsx";
import Download from "../components/Download/Download.jsx";
import CrossLink from "../components/CrossLink/CrossLink.jsx";
import ConsoleShot from "../components/ConsoleSection/ConsoleShot.jsx";
import Notifications from "../components/Notifications/Notifications.jsx";
import Mobile from "../components/Mobile/Mobile.jsx";
import Terminal from "../components/Terminal/Terminal.jsx";
import Tour from "../components/Tour/Tour.jsx";
import Glyph from "../components/Glyph/Glyph.jsx";
import TypeCycle from "../components/TypeCycle/TypeCycle.jsx";
import Starfield from "../components/Starfield/Starfield.jsx";
import { OsIcon, PLATFORMS } from "../components/OsIcons/OsIcons.jsx";
import { WEB_APP_URL, CONSOLE_URL } from "../lib/nav.js";
import styles from "./home.module.css";

export function meta() {
  return [
    { title: "inbox2 | One app for all your mail" },
    {
      name: "description",
      content:
        "inbox2 gives you the same inbox, views and rules on macOS, Windows, Linux, iOS, Android, the browser and the terminal. The apps are free and native, work offline, and run over the Gmail, Microsoft 365, IMAP and WhatsApp accounts you already have.",
    },
  ];
}

// The surfaces the app actually ships on, typed one after another under the
// headline. Order = biggest screen to smallest, then the two browsers of a sort.
const SURFACES = ["Mac", "PC", "Linux box", "iPhone", "Android", "browser", "terminal"];

/** Kicker -> anchor id, so the footer can link straight at a feature row. */
const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-");

/** The hero's scroll tour (HeroBuild): the desktop section's copy, floating up
 *  on yellow over the screens it describes. Slide 0 is the assembled window. */
const HERO_SLIDES = [
  {
    kicker: "Desktop",
    caption: "Your domain and your Gmail, Microsoft 365, IMAP and WhatsApp channels share one inbox, stored in a local SQLite file. It works on a plane.",
  },
  {
    shot: "spaces",
    alt: "Spaces boards in the desktop app",
    caption: "Spaces sort mail onto Support, Sales, Finance and Triage boards with counts, assignees and a holding pen.",
  },
  {
    shot: "conversation",
    alt: "A conversation in the desktop app",
    caption: "Every action works from the keyboard, with Gmail or Outlook shortcuts.",
  },
  {
    shot: "calendar",
    alt: "The calendar in the desktop app",
    caption: "It runs natively on macOS, Windows and Linux, and checks for a signed update and offers it in the bell.",
  },
];

const WEB_POINTS = [
  ["globe", "Each domain gets its own workspace and URL, and one view covers the whole organisation"],
  ["shield", "HTML mail opens in a sandboxed frame, and remote images stay blocked until you allow them"],
  ["calendar", "Answer invites, send counter-proposals and use the scheduling assistant"],
  ["console", "Admins run domains, DNS health, rules, keys and billing from the console"],
];

const FEATURES = [
  ["conversation", "On-device AI", "Mail sorted and summarised on your device", "Classification and summaries run on the device. Mail never leaves it.", "Every platform runs the same free model, and Apple devices use Apple Intelligence where it exists."],
  ["whatsapp", "External channels", "Use the accounts you have", "They sync straight into a local SQLite file on your device and never touch our servers.", "Gmail and Microsoft 365 push new mail in real time without exposing your token."],
  ["search", "Search", "Search by meaning and by exact words", "Search combines meaning and exact words across all your mail, and AI agents get an audited interface to it.", "Every agent call is permissioned and logged."],
  ["explorer", "Command Center", "Your contacts in one graph", "Every contact, mailbox and thread appears in one graph you can search, scroll and open.", "Your device builds it from your own mail."],
  ["meeting", "Calendar", "Answer invites and join meetings in one tap", "Accept an emailed invite, see who else said yes, and join Meet, Teams or Zoom from the event.", "The calendar also handles working hours, out-of-office replies and counter-proposals."],
  ["outlook", "Privacy", "Your mail stays private", "Remote images stay blocked and load through our proxy, quoted text collapses, and sealed domains get end-to-end encryption.", "Open tracking is opt-in per domain, and it flags Apple and Gmail prefetches apart from real opens."],
];

const TAGS = [
  ["Free", "on every device you own"],
  ["Native", "on seven platforms"],
  ["Offline-first", "your mail in a local file"],
];

export default function Product() {
  return (
    <>
      <section className={`${styles.hero} on-dark`}>
        <Starfield />
        <div className={styles.glow} aria-hidden="true" />
        <div className={`wrap ${styles.heroInner}`}>
          <ul className={styles.tags}>
            {TAGS.map(([num, sub]) => <li key={num}><b>{num}</b><span>{sub}</span></li>)}
          </ul>
          <h1 className={styles.h1} aria-label="All your mail in one app on your Mac, your PC, your Linux box, your iPhone, your Android, your browser and your terminal.">
            <span aria-hidden="true">
              All your mail<br />in one app on<br /><span className={styles.typed}><span className={styles.your}>your </span><TypeCycle words={SURFACES} /></span>
            </span>
          </h1>
          <p className={styles.lede}>Read Gmail, Microsoft 365, IMAP and WhatsApp in one inbox. Your mail stays in a file on your device, so the app opens with no connection.</p>
          <div className={styles.ctas}>
            <DownloadButton />
            <Button size="lg" variant="glass" href={WEB_APP_URL}>Open the web app</Button>
          </div>
          <div className={styles.platforms}>
            {PLATFORMS.map((p) => <Link key={p.id} to="/download"><OsIcon id={p.id} />{p.name}</Link>)}
            <a href={WEB_APP_URL}><OsIcon id="web" />Web</a>
          </div>
        </div>
        <div className={styles.heroShot}>
          <span className={styles.envA} aria-hidden="true">
            <img className={styles.env} src="/assets/3d/env-green.webp" alt="" />
            <img className={styles.badge} src="/assets/channels/whatsapp.svg" alt="" />
          </span>
          <span className={styles.envB} aria-hidden="true">
            <img className={styles.env} src="/assets/3d/env-pink.webp" alt="" />
            <img className={styles.badge} src="/assets/channels/gmail.svg" alt="" />
          </span>
          <HeroBuild alt="The desktop app showing the unified inbox" slides={HERO_SLIDES} className={styles.frame} />
        </div>
        <div className={`${styles.fade} ${styles.fadeHero}`} aria-hidden="true" />
      </section>

      <section id="web" className={`${styles.web} on-dark`}>
        <div className={styles.glowB} aria-hidden="true" />
        <div className={`wrap ${styles.webHead}`}>
          <div className={styles.webText}>
            <span className="kicker kicker--accent">Web</span>
            <h2 className={styles.h2}>inbox2 in the browser</h2>
            <p className="lede">mail.inbox2.com is the full client for hosted domains, plus the console where admins run DNS, people, rules and billing. It runs wherever a browser does.</p>
          </div>
          <ul className={`${styles.points} ${styles.pointsDark}`}>{WEB_POINTS.map(([g, p]) => <li key={p}><Glyph id={g} />{p}</li>)}</ul>
        </div>
        <div className={styles.webShot}>
          <WindowFrame src="/assets/shots/triage.webp" alt="The unified inbox as a triage grid" bare reflect className={styles.frame} />
        </div>
        <div className={styles.fade} aria-hidden="true" />
      </section>

      <Mobile />

      <Terminal />

      <section className={styles.features}>
        <div className={`wrap ${styles.rows}`}>
          {FEATURES.map(([shot, kicker, title, body, sub], i) => (
            <div key={title} id={slug(kicker)} className={`${styles.row} ${i % 2 ? styles.flip : ""}`}>
              <div className={styles.rowText}>
                <span className="kicker">{kicker}</span>
                <h3 className={styles.h3}>{title}</h3>
                <p className={styles.rowBody}>{body}</p>
                <p className={styles.rowSub}>{sub}</p>
              </div>
              {/* The heading and both paragraphs beside it say what this shows. */}
              <WindowFrame src={`/assets/shots/${shot}.webp`} alt="" bare />
            </div>
          ))}
        </div>
      </section>

      <Notifications />

      <Tour />

      <Download />

      <CrossLink
        kicker="inbox2 MX"
        title="Point your whole domain at inbox2"
        cta="See how MX works"
        to="/mx"
        img="/assets/3d/pool.webp"
        alt="Envelopes settled in the domain's inbox"
        body="Point your MX record at us and every message to @company.com lands in the domain's inbox, so you can delete your forwarding rules. Each person filters their own view over it, and rules push the rest to a colleague, an AI agent or a webhook. Plans start at €0. We host it, or you run it yourself."
      />

      <section className={`${styles.consoleCta} on-dark`}>
        <div className={`wrap ${styles.consoleGrid}`}>
          <div className={styles.consoleInner}>
            <h2 className={styles.h2}>Manage your domain</h2>
            <p className="lede">The console holds domains, DNS health, people, routing rules, billing and API keys.</p>
            <Button variant="offset" href={CONSOLE_URL}>Open the console</Button>
          </div>
          <div className={styles.consoleShot} aria-hidden="true"><ConsoleShot /></div>
        </div>
      </section>
    </>
  );
}
