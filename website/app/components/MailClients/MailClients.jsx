import styles from "./MailClients.module.css";

const STEPS = [
  "Ask an admin to turn on mail clients.",
  "Create an app password in Settings. You see it once.",
  "Enter mx.inbox2.com in your mail client, with port 993 for IMAP and 465 for SMTP.",
];

/** IMAP and SMTP for other mail clients (docs/Mail-Clients.md): the fallback,
 *  so it gets one quiet row. Paid plans; off until an admin turns it on. */
export default function MailClients() {
  return (
    <section id="mail-clients" className={styles.section}>
      <div className={`wrap ${styles.inner}`}>
        <div className={styles.text}>
          <span className="kicker">IMAP and SMTP</span>
          <h2 className={styles.h2}>Use Outlook or Apple Mail</h2>
          <p className={styles.body}>An admin can turn on IMAP and SMTP for the organisation. Each person then creates an app password and connects any IMAP client, or a scanner or CRM that sends by SMTP.</p>
          <p className={styles.sub}>A mail client shows your own mailbox. Shared addresses and sealed domains open in the inbox2 apps. Included in paid plans.</p>
        </div>
        <ol className={styles.steps}>
          {STEPS.map((s) => <li key={s}><span>{s}</span></li>)}
        </ol>
      </div>
    </section>
  );
}
