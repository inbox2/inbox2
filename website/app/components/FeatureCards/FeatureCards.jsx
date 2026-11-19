import { Link } from "react-router";
import styles from "./FeatureCards.module.css";

const CARDS = [
  {
    tone: "tint",
    title: "Filter the inbox down to your work",
    body: "A view filters the domain's inbox down to your part of it: support tickets, mentions, one customer or one country. The view belongs to you and the mail stays shared.",
    link: "How views work",
    img: "/assets/3d/views.webp",
    alt: "Three frosted panes stacked over the domain's inbox",
  },
  {
    tone: "ink",
    title: "Route mail with rules",
    body: "A rule sends the message to a colleague, to an on-device AI agent that drafts the reply, or to a webhook that updates your CRM.",
    link: "Read the rules syntax",
    img: "/assets/3d/routes.webp",
    alt: "A sorting box with three coloured chutes",
  },
  {
    tone: "grey",
    title: "Run it on your own servers or in your cloud",
    body: "Run the whole stack in your data centre or with an EU host. On sealed domains the client encrypts mail with keys you hold.",
    link: "Self-host in 20 minutes",
    img: "/assets/3d/sovereign.webp",
    alt: "A locked server tower with a stack of envelopes beside it",
    to: "/topologies",
  },
];

export default function FeatureCards() {
  return (
    <section className={styles.section}>
      <div className={`wrap ${styles.inner}`}>
        <h2 className={styles.h2}>Let rules sort the domain's inbox</h2>
        <p className={`lede ${styles.lede}`}>Write a rule once. It runs on every message after that.</p>
        <div className={styles.cards}>
          {CARDS.map((c) => (
            <article key={c.title} className={`${styles.card} ${styles[c.tone]}`}>
              <h3>{c.title}</h3>
              <p>{c.body}</p>
              <Link to={c.to || "/mx"} className={styles.link}>{c.link}</Link>
              <div className={styles.art}><img src={c.img} alt={c.alt} loading="lazy" /></div>
            </article>
          ))}
        </div>
      </div>
    </section>
  );
}
