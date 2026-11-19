import Button from "../Button/Button.jsx";
import Model3D from "../Model3D/Model3D.jsx";
import styles from "./Sovereignty.module.css";

const POINTS = [
  "Hosted domains run on server-side MX, or the apps work client-side over your existing tenant",
  "The client encrypts with libsodium, and your organisation holds the keys",
  "Self-host, send through your own servers and keep AI on the device, and your mail stays with you",
  "Your ops team deploys it from a single container image",
];

export default function Sovereignty({ compact = false }) {
  return (
    <section className={`${styles.section} on-dark`}>
      <div className={`wrap ${styles.inner}`}>
        <div className={styles.text}>
          <h2 className={styles.h2}>Keep your mail under your own control</h2>
          {compact ? (
            <p className={styles.p}>You get client-side encryption with keys you hold, AI that runs on the device, and a single container image your ops team deploys. Self-host, send through your own servers and keep AI triage off or on the device, and your mail never reaches a US processor.</p>
          ) : (
            <>
              <p className={styles.p}>inbox2 runs on your servers and encrypts on the client. Send through your own servers, keep AI triage off or on the device, and your mail never reaches a US processor. Billing runs through Stripe and never sees your mail.</p>
              <ul className={styles.list}>
                {POINTS.map((p) => <li key={p}>{p}</li>)}
              </ul>
            </>
          )}
          <div><Button href="mailto:hello@inbox2.com?subject=Briefing">Request a briefing</Button></div>
        </div>
        <div className={styles.art}>
          <div className={styles.glow} aria-hidden="true" />
          <Model3D src="/assets/3d/sovereign.glb" alt="A locked server tower with a stack of envelopes beside it" className={styles.model} />
        </div>
      </div>
    </section>
  );
}
