import Button from "../components/Button/Button.jsx";
import TopologyLab from "../components/TopologyLab/TopologyLab.jsx";
import ModeTable from "../components/ModeTable/ModeTable.jsx";
import Sovereignty from "../components/Sovereignty/Sovereignty.jsx";
import styles from "./topologies.module.css";

export function meta() {
  return [
    { title: "Deployment modes | inbox2" },
    {
      name: "description",
      content:
        "inbox2 runs in four modes: free on your own devices, hosted by us, in your own cloud, or on-prem with a hosted MX. Every mode uses the same apps and the same inbox.",
    },
  ];
}

export default function Topologies() {
  return (
    <>
      <section className={`${styles.hero} on-dark`}>
        <div className={styles.glow} aria-hidden="true" />
        <div className={`wrap ${styles.inner}`}>
          <div className={styles.head}>
            <div className={styles.headText}>
              <span className="kicker kicker--accent">Deployment modes</span>
              <h1 className={styles.h1}>Four ways to run inbox2</h1>
            </div>
            <div className={styles.headRight}>
              <p className={styles.lede}>The same apps and the same inbox run four ways: free and local on your own devices, hosted by us, in your own cloud, or in your own building with our MX receiving the mail. You can start in one mode and move to another later without switching apps or leaving your data behind.</p>
              <div className={styles.ctas}>
                <Button href="mailto:hello@inbox2.com?subject=Self-hosting">Talk to us about self-hosting</Button>
                <Button variant="glass" href="https://github.com/inbox2/inbox2">Read the deployment docs</Button>
              </div>
            </div>
          </div>
          <TopologyLab />
        </div>
      </section>

      <section className={styles.modes}>
        <div className={`wrap ${styles.modesInner}`}>
          <div className={styles.modesHead}>
            <h2 className={styles.h2}>The same apps in every mode</h2>
            <p className="lede">Move between modes and keep your apps and your data.</p>
          </div>
          <ModeTable />
        </div>
      </section>

      <Sovereignty compact />
    </>
  );
}
