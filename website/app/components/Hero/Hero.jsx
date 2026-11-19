import TypeCycle from "../TypeCycle/TypeCycle.jsx";
import Button from "../Button/Button.jsx";
import Starfield from "../Starfield/Starfield.jsx";
import { SIGNUP_URL, WEB_APP_URL } from "../../lib/nav.js";
import styles from "./Hero.module.css";

const SPRITES = 9;
const LOOP = 18;

// The channels inbox2 actually connects — one badge per flying envelope, so the
// stream reads as "every channel", not just SMTP. Order = the order they fly in.
const CHANNELS = ["gmail", "whatsapp", "office365", "instagram", "imap", "messenger"];

// The envelopes settled in the tray are baked into pool.webp, so their badges are
// hand-placed on each flap: [channel, x%, y%, rotation to match the flap's tilt].
const POOL_BADGES = [
  ["whatsapp", 63.4, 17.7, -20],
  ["gmail", 38.9, 40.7, -3],
  ["instagram", 32.9, 51.7, 9],
  ["office365", 53.9, 48.6, 14],
  ["imap", 75.4, 54.4, 13],
  ["messenger", 64.5, 63.0, 19],
];

/** The tray plus the channel badges printed on the envelopes already in it. */
function Tray({ className, alt = "" }) {
  return (
    <span className={`${styles.tray} ${className}`}>
      <img className={styles.trayImg} src="/assets/3d/pool.webp" alt={alt} />
      {POOL_BADGES.map(([channel, x, y, rot]) => (
        /* Hand-placed on the envelope flaps baked into pool.webp: the
           coordinates are the data, not styling. */
        /* eslint-disable react/forbid-dom-props */
        <img
          key={channel}
          className={styles.trayBadge}
          src={`/assets/channels/${channel}.svg`}
          alt=""
          style={{ left: `${x}%`, top: `${y}%`, "--rot": `${rot}deg` }}
        />
        /* eslint-enable react/forbid-dom-props */
      ))}
    </span>
  );
}

const ROUTES = [
  ["Invoices", "Finance view", "accent"],
  ["Refund requests", "Triage agent", "offset"],
  ["New signups", "Webhook /crm", "ink"],
  ["Mentions Sara", "Sara", "blue"],
];

export default function Hero() {
  return (
    <section className={`${styles.hero} on-dark`}>
      <Starfield />
      <div className={styles.glowA} aria-hidden="true" />
      <div className={styles.glowB} aria-hidden="true" />

      {/* 3D layer: the tray, the endless stream, and the leaf */}
      <div className={styles.art} aria-hidden="true">
        <Tray className={styles.pool} />
        {Array.from({ length: SPRITES }, (_, i) => (
          /* Each sprite enters the loop at its own offset; a class per index
             would be the same numbers, just written in CSS. */
          /* eslint-disable react/forbid-dom-props */
          <span key={i} className={styles.sprite} style={{ animationDelay: `${-i * (LOOP / SPRITES)}s` }}>
            <span className={styles.sway} style={{ animationDelay: `${-i * 0.7}s` }}>
              <span className={styles.grow} style={{ animationDelay: `${-i * (LOOP / SPRITES)}s` }}>
                <img className={styles.env} src={i % 3 === 2 ? "/assets/3d/env-green.webp" : "/assets/3d/env-pink.webp"} alt="" />
                <img className={styles.badge} src={`/assets/channels/${CHANNELS[i % CHANNELS.length]}.svg`} alt="" />
              </span>
            </span>
          </span>
          /* eslint-enable react/forbid-dom-props */
        ))}
        <span className={styles.leaf}>
          <img className={styles.env} src="/assets/3d/env-green.webp" alt="" />
          <img className={styles.badge} src="/assets/channels/gmail.svg" alt="" />
        </span>
      </div>

      <div className={`wrap ${styles.copy}`}>
        <h1 className={styles.h1}>
          One inbox<br />for your<br /><em><TypeCycle words={["domain"]} once /></em>
        </h1>
        <p className={styles.lede}>
          Every message to <code className={styles.code}>@company.com</code> lands in the domain's inbox. Each person builds a view over it, and rules route the rest.
        </p>
        <div className={styles.ctas}>
          <Button size="lg" href={SIGNUP_URL}>Start free</Button>
          <Button size="lg" variant="glass" href={WEB_APP_URL}>Try it on your Gmail</Button>
        </div>
        <Tray className={styles.poolMobile} alt="Envelopes settled in the domain's inbox" />
      </div>

      <div className={styles.widget}>
        <div className={styles.brand}>
          <span className={styles.fav} aria-hidden="true">
            <svg viewBox="0 0 24 24" width="17" height="17"><path d="M12 3.2 20.8 12 12 20.8 3.2 12Z" fill="#fff" opacity="0.95" /><circle cx="12" cy="12" r="3.1" fill="#111" /></svg>
          </span>
          <span className={styles.wordmark}>Company</span>
        </div>
        <h3>Test a rule on your mail</h3>
        <div className={styles.field}>
          <div><small>Domain</small><b>@company.com</b></div>
          <span className={styles.tag}>4,812 in inbox</span>
        </div>
        <div className={styles.field}>
          <div><small>Rule</small><b>from:*@vendor.io subject:invoice</b></div>
        </div>
        <div className={styles.routes}>
          {ROUTES.map(([from, to, dot]) => (
            <div key={from} className={styles.route}>
              <span>{from}</span>
              <svg viewBox="0 0 34 10" width="34" height="10" aria-hidden="true"><path d="M0 5 H26" stroke="#111" strokeWidth="2" /><path d="M24 0 L34 5 L24 10 Z" fill="#111" /></svg>
              <span className={styles.to}><i className={styles[dot]} />{to}</span>
            </div>
          ))}
        </div>
        <Button variant="ink" href={WEB_APP_URL} className={styles.widgetBtn}>Try it on your Gmail</Button>
      </div>
    </section>
  );
}
