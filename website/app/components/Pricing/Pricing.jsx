import Button from "../Button/Button.jsx";
import { SIGNUP_URL } from "../../lib/nav.js";
import styles from "./Pricing.module.css";

/* Mirrors Plan::DEFAULTS, Plan::DISK_GB_PER_MEMBER, Plan::ESP_MONTHLY_SENDS and
   Plan#mail_clients? in the API (tier, price in euros, domain/collaborator caps,
   spam filter, AI triage, mail size, Disk, API messages, IMAP and SMTP).
   Change one, change the other. The size is what a domain can receive: a send
   stops at 25 MB of attachments on every plan, and larger files go as a Disk link. */
const PLANS = [
  {
    name: "Free",
    price: "0",
    sub: "Get a domain online in an afternoon.",
    features: [
      ["1", " connected domain"],
      ["Just you, solo owner"],
      ["Inbound MX and signed outbound"],
      ["DKIM, SPF and MTA-STS set up for you"],
      ["Mail up to ", "20 MB"],
    ],
    cta: "Start free",
  },
  {
    name: "Startup",
    price: "19.99",
    sub: "For a few people sharing one inbox.",
    featured: true,
    features: [
      ["2", " connected domains"],
      ["Owner ", "+ 2", " collaborators"],
      ["Spam filter", " included"],
      ["AI auto-triage", " into Spaces"],
      ["Receive mail up to ", "100 MB"],
      ["10 GB", " of Disk for each member"],
      ["End-to-end encrypted", " domains"],
      ["10,000", " API messages a month"],
      ["IMAP and SMTP", " for other mail clients"],
    ],
    cta: "Start free",
  },
  {
    name: "Serial Entrepreneur",
    price: "49.99",
    sub: "For running several things at once.",
    features: [
      ["Unlimited", " domains"],
      ["Unlimited", " collaborators"],
      ["Spam filter on every domain"],
      ["AI auto-triage on every domain"],
      ["Receive mail up to ", "100 MB"],
      ["30 GB", " of Disk for each member"],
      ["End-to-end encrypted", " domains"],
      ["50,000", " API messages a month"],
      ["IMAP and SMTP", " for other mail clients"],
    ],
    cta: "Start free",
  },
];

/** Cloud MX pricing. Odd-index fragments in a feature line are the emphasis. */
export default function Pricing() {
  return (
    <section className={styles.section} id="pricing">
      <div className={`wrap ${styles.inner}`}>
        <div className={styles.head}>
          <span className="kicker">Pricing</span>
          <h2 className={styles.h2}>One price per organisation</h2>
          <p className="lede">You pay when we run the mail server for your domain. Everything else costs nothing: the apps on every platform, and inbox2 over the Gmail, Microsoft 365 or IMAP accounts you already have.</p>
        </div>
        <div className={styles.plans}>
          {PLANS.map((plan) => (
            <article key={plan.name} className={`${styles.plan} ${plan.featured ? styles.featured : ""}`}>
              <div className={styles.planInner}>
                <div className={styles.tier}>
                  {plan.name}
                  {plan.featured && <span className={styles.pop}>Most popular</span>}
                </div>
                <div className={styles.amt}>
                  <span className={styles.cur}>€</span>{plan.price}<span className={styles.per}>/mo</span>
                </div>
                <p className={styles.sub}>{plan.sub}</p>
                <ul className={styles.list}>
                  {plan.features.map((parts, i) => (
                    <li key={i}>{parts.map((part, j) => (j % 2 ? <b key={j}>{part}</b> : <span key={j}>{part}</span>))}</li>
                  ))}
                </ul>
                <Button variant={plan.featured ? "accent" : "glassink"} href={SIGNUP_URL} className={styles.cta}>{plan.cta}</Button>
              </div>
            </article>
          ))}
        </div>
        <p className={styles.foot}>Prices are per organisation, per month, excluding VAT. Cancel whenever you like. Every client exports your mail on the way out.</p>
      </div>
    </section>
  );
}
