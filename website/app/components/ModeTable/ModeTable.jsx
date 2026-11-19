import { TOPOLOGIES } from "../TopologyLab/topologies.js";
import styles from "./ModeTable.module.css";

const ROWS = [
  ["Where the mail lives", ["A SQLite file on your device", "inbox2 Cloud, synced to every device", "Your cloud account", "Your own building"]],
  ["Inbound mail", ["Synced from Gmail, Microsoft 365, IMAP", "inbox2 MX receives it", "Your MX, in your cloud", "inbox2 MX relays it, and port 25 stays closed"]],
  ["Outbound mail", ["Through the provider you connected", "inbox2 SMTP, DKIM-signed", "Your ESP: SES, SendGrid, Postmark", "Your ESP: SES, SendGrid, Postmark"]],
  ["AI triage", ["On the device", "On the device, or inbox2 cloud on paid plans", "On the device", "On the device"]],
  ["Encryption keys", ["Yours, on the device", "Yours, client-side, per tenant", "Yours", "Yours"]],
  ["Who runs it", ["Nobody, there is nothing to host", "inbox2", "Your ops team, one container image", "Your ops team, one container image"]],
  ["Price", ["Free", "Free tier, flat rate per organisation", "Licence, talk to us", "Licence, talk to us"]],
];

const TIER_CLASS = { Free: "free", "Free / Paid": "paid", Advanced: "adv" };

/** What actually differs between the four deployment modes. */
export default function ModeTable() {
  return (
    <div className={styles.table}>
      <div className={`${styles.row} ${styles.head}`}>
        <span />
        {TOPOLOGIES.map((t) => (
          <div key={t.id} className={styles.mode}>
            <span className={`${styles.tier} ${styles[TIER_CLASS[t.tier]]}`}>{t.tier}</span>
            <span className={styles.label}>{t.label}</span>
            <span className={styles.sub}>{t.sub}</span>
          </div>
        ))}
      </div>
      {ROWS.map(([name, cells]) => (
        <div key={name} className={styles.row}>
          <span className={styles.name}>{name}</span>
          {cells.map((c, i) => <span key={i} className={styles.cell}>{c}</span>)}
        </div>
      ))}
    </div>
  );
}
