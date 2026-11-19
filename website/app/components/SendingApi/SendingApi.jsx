import Button from "../Button/Button.jsx";
import styles from "./SendingApi.module.css";

const API_GUIDE = "https://github.com/inbox2/inbox2/blob/main/docs/ESP.md";

const POINTS = [
  ["One call per message", "Post the message with a sending key. The key belongs to your organisation, so your code holds nobody's login."],
  ["A status for every recipient", "Each recipient is queued, delivered, deferred, bounced or failed. Your app gets a signed webhook when the status changes."],
  ["One suppression list", "An address that bounced or complained is skipped, for your app's mail and for your team's."],
  ["Send from a subdomain", "Add a domain that only sends, such as mail.yourapp.com. It needs one DNS record and hosts no mailboxes."],
];

const SAMPLE = `curl https://api.inbox2.com/api/v1/esp/emails \\
  -H "Authorization: Bearer isk_…" \\
  -H "Content-Type: application/json" \\
  -H "Idempotency-Key: order-1042" \\
  -d '{
    "from": "Acme <billing@acme.com>",
    "to": ["jane@example.com"],
    "subject": "Your receipt",
    "html": "<p>Thanks for your order.</p>",
    "tag": "receipt"
  }'`;

/** The sending API (docs/ESP.md): paid plans, Plan::ESP_MONTHLY_SENDS a month. */
export default function SendingApi() {
  return (
    <section id="sending-api" className={`${styles.section} on-dark`}>
      <div className={`wrap ${styles.inner}`}>
        <div className={styles.head}>
          <div className={styles.headText}>
            <span className="kicker kicker--accent">Sending API</span>
            <h2 className={styles.h2}>Send your app's mail from your domain</h2>
            <p className="lede">Your app sends receipts, sign-in codes and alerts with one API call. The mail leaves from your own domain, signed with DKIM, and you get a status for each recipient.</p>
            <div><Button href={API_GUIDE}>Read the API guide</Button></div>
          </div>
          <pre className={styles.code}><code>{SAMPLE}</code></pre>
        </div>
        <div className={styles.points}>
          {POINTS.map(([t, b]) => (
            <div key={t}><h3>{t}</h3><p>{b}</p></div>
          ))}
        </div>
        <p className={styles.foot}>Included in Startup and Serial Entrepreneur: 10,000 and 50,000 messages a month.</p>
      </div>
    </section>
  );
}
