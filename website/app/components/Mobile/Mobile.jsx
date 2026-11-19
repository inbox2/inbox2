import { useEffect, useRef } from "react";
import { Link } from "react-router";
import Glyph from "../Glyph/Glyph.jsx";
import PhoneFrame from "../PhoneFrame/PhoneFrame.jsx";
import { OsIcon, PLATFORMS } from "../OsIcons/OsIcons.jsx";
import { useReveal } from "../../lib/reveal.js";
import styles from "./Mobile.module.css";

const POINTS = [
  ["inbox", "Every account and channel sits in one inbox stored on the phone, so it opens with no signal"],
  ["waveform", "Talk to your inbox with Bridge. The voice agent reads, searches and drafts on screen, and never sends for you"],
  ["lock", "Live Activities and the Dynamic Island show the newest unread on the lock screen, and you act on it while the phone stays locked"],
  ["bell", "Gmail and Microsoft 365 push new mail in real time without handing anyone your token"],
  ["calendar", "Answer invitations and join Meet, Teams or Zoom in one tap"],
  ["shield", "Classification and summaries run on the phone, with the same free model as the desktop"],
];

const SHOTS = [
  ["m-inbox", "The unified inbox on iPhone"],
  ["m-conversation", "A conversation with its AI summary on iPhone"],
  ["m-bridge", "The Bridge voice agent on iPhone"],
  ["m-calendar", "The calendar on iPhone"],
];

/** Icons for the Live Activity's own buttons — same three verbs, same order as
 *  Widgets/Inbox2Widgets.swift. Drawn rather than SF Symbols, which aren't ours. */
const ACTIONS = [
  ["Read", "M3 8.5 12 3l9 5.5V20H3zM3 8.5 12 15l9-6.5"],
  ["Archive", "M3 4h18v4H3zM5 8v12h14V8M9.5 12h5"],
  ["Trash", "M4 6h16M9 6V3.5h6V6M6 6v14h12V6M10 10v6M14 10v6"],
];

/** Progress of the Live Activity panel's scroll track through the viewport,
 *  written onto the track as --panel-bleed (the surface opening out to the full
 *  window and closing again) and --card-in (the Live Activity arriving on the
 *  lock screen). CSS scroll-driven animation would do this without JS, but
 *  Firefox still has no animation-timeline, so one rAF-throttled scroll handler
 *  drives it everywhere rather than shipping two paths. Until it runs, the vars
 *  are unset and the panel is the plain card with the notification on it, which
 *  is also what reduced motion keeps. */
function useScrollStage() {
  const ref = useRef(null);
  useEffect(() => {
    const el = ref.current;
    if (!el || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return undefined;
    el.dataset.stage = "on";
    let frame = 0;
    const ramp = (p, a, b) => Math.min(1, Math.max(0, (p - a) / (b - a)));
    const paint = () => {
      frame = 0;
      const r = el.getBoundingClientRect();
      // 0 when the track's top meets the bottom of the window, 1 when its
      // bottom leaves the top — the `cover` range of a CSS view() timeline.
      const p = (window.innerHeight - r.top) / (window.innerHeight + r.height);
      el.style.setProperty("--panel-bleed", (ramp(p, 0.3, 0.46) - ramp(p, 0.66, 0.82)).toFixed(3));
      el.style.setProperty("--card-in", ramp(p, 0.5, 0.6).toFixed(3));
    };
    const onScroll = () => { frame ||= requestAnimationFrame(paint); };
    paint();
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll);
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", onScroll);
    };
  }, []);
  return ref;
}

/** The Mail Live Activity, drawn. It can't be screenshotted: ActivityKit refuses
 *  a push-token activity in the simulator, and the physical phone holds real
 *  mail. So this is the SwiftUI card (Widgets/Inbox2Widgets.swift — brand mark,
 *  sender, subject, snippet, Read / Archive / Trash, the +N pill) rebuilt in CSS
 *  over a lock screen. Keep the two in step when the card changes. */
function LockScreen() {
  return (
    <div className={styles.lock}>
      <div className={styles.island}>
        <img src="/assets/mark.svg" alt="" />
        <b>34</b>
      </div>
      <p className={styles.lockDate}>Sunday 13 September</p>
      <p className={styles.lockClock}>9:41</p>
      <div className={styles.card}>
        <div className={styles.cardHead}>
          <img className={styles.cardMark} src="/assets/mark.svg" alt="" />
          <div className={styles.cardText}>
            <p className={styles.cardTop}>
              <strong>Priya Raman</strong>
              <span>2 min ago</span>
            </p>
            <p className={styles.cardSubject}>Re: Aurora rebrand, final logo lockups</p>
            <p className={styles.cardSnippet}>These look incredible. The board signed off this morning, unanimously, which almost never happens here.</p>
          </div>
        </div>
        <div className={styles.cardActions}>
          {ACTIONS.map(([label, d]) => (
            <span key={label} className={label === "Trash" ? styles.trash : ""}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={d} /></svg>
              {label}
            </span>
          ))}
          <b className={styles.unread}>+33</b>
        </div>
      </div>
    </div>
  );
}

export default function Mobile() {
  const reveal = useReveal();
  const stage = useScrollStage();
  return (
    <section id="mobile" className={styles.section}>
      <div className={`wrap ${styles.head}`}>
        <span className="kicker">Mobile</span>
        <h2 className={styles.h2}>inbox2 on your phone</h2>
        <p className="lede">Native apps for iPhone, iPad and Android. They open with no signal and use the same Spaces and rules as your desktop.</p>
        <div className={styles.badges}>
          {PLATFORMS.filter((p) => p.id === "ios" || p.id === "android").map((p) => (
            <Link key={p.id} to="/download"><OsIcon id={p.id} />{p.name}<em>{p.sub}</em></Link>
          ))}
        </div>
      </div>

      <ul className={`wrap ${styles.points}`}>
        {POINTS.map(([g, p]) => <li key={p}><Glyph id={g} />{p}</li>)}
      </ul>

      <div className={`wrap ${styles.phones}`}>
        {SHOTS.map(([shot, alt]) => (
          <PhoneFrame key={shot} src={`/assets/shots/${shot}.webp`} alt={alt} />
        ))}
      </div>

      {/* Track and pin: the panel sticks at the top of the window for the length
          of the track, so the sequence gets a screen and a bit of scroll to play
          out in. Both collapse to nothing until useScrollStage marks the track. */}
      <div ref={stage} className={styles.activityTrack}>
        <div className={styles.activityPin}>
          <div className={`wrap on-dark ${styles.activity}`}>
            <div ref={reveal} className={`reveal reveal--left ${styles.activityText}`}>
              <span className="kicker kicker--accent">Live Activities</span>
              <h3 className={styles.h3}>See the newest unread on the lock screen</h3>
              <p className={styles.body}>Mail arrives as a live card on the lock screen and in the Dynamic Island. Deal with one message and the card moves to the next unread, and it closes when nothing unread is left.</p>
              <p className={styles.sub}>Read, Archive and Trash run in the background while the phone stays locked, and the card shows the same count as the app icon.</p>
            </div>
            <PhoneFrame className={styles.lockPhone}><LockScreen /></PhoneFrame>
          </div>
        </div>
      </div>
    </section>
  );
}
