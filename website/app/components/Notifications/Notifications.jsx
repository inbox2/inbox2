import { OsIcon } from "../OsIcons/OsIcons.jsx";
import { useReveal } from "../../lib/reveal.js";
import styles from "./Notifications.module.css";

// The three cards are shot straight out of the app's notification window
// (website/scripts/uishots.mjs), so what the site shows is what arrives. Each
// shot carries the window's own dark bezel (42px on a 1428px frame, 27–38px
// along the bottom), cropped away in CSS so the card sits on the desktop like
// the real thing.
const CARDS = [
  ["notif-mail", "New mail", "Read, archive, delete or reply without opening the app."],
  ["notif-invite", "A meeting invitation", "Accept or decline straight from the card."],
  ["notif-meeting", "Ten minutes before a meeting", "Join Meet, Teams or Zoom in one tap, or snooze it if you're mid-sentence."],
];

const MENUS = ["File", "Edit", "View", "Mailbox", "Message", "Window", "Help"];

function Row({ shot, title, body, fromRight }) {
  const reveal = useReveal();
  return (
    <figure className={styles.row}>
      <div ref={reveal} className={`${styles.desktop} ${fromRight ? "reveal--right" : "reveal--left"}`} aria-hidden="true">
        <div className={styles.menubar}>
          <OsIcon id="macos" />
          <b>inbox2</b>
          {MENUS.map((m) => <span key={m}>{m}</span>)}
          <em>Tue 13 Sep&nbsp;&nbsp;14:32</em>
        </div>
        <div className={styles.card}>
          {/* Not lazy: WebKit never loads a lazy image inside the size-contained mock. */}
          <img src={`/assets/shots/${shot}.webp`} alt="" />
        </div>
      </div>
      <figcaption>
        <strong>{title}</strong>
        <span>{body}</span>
      </figcaption>
    </figure>
  );
}

export default function Notifications() {
  return (
    <section className={`${styles.section} on-dark`}>
      <div className={`wrap ${styles.head}`}>
        <span className="kicker kicker--accent">Notifications</span>
        <h2 className={styles.h2}>Act on mail from the notification</h2>
        <p className="lede">Mail, invitations and meetings arrive as a stack of glass cards in the corner of the screen, and each card carries the buttons that item needs. You can hand them to the system notification centre, or turn them off.</p>
      </div>
      <div className={`wrap ${styles.rows}`}>
        {CARDS.map(([shot, title, body], n) => <Row key={shot} shot={shot} title={title} body={body} fromRight={n % 2 === 1} />)}
      </div>
    </section>
  );
}
