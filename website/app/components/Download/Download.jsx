import { OsIcon, PLATFORMS, DownloadArrow } from "../OsIcons/OsIcons.jsx";
import { WEB_APP_URL, CLI_RELEASE_PAGE } from "../../lib/nav.js";
import { useLatestRelease, installerFor, formatSize } from "../../lib/releases.js";
import styles from "./Download.module.css";

/** The five OS tiles. */
export default function Download({ dark = false, heading = "Free apps for every platform", h1 = false }) {
  const H = h1 ? "h1" : "h2";
  const release = useLatestRelease();
  const build = (id) => release?.downloads?.find((d) => d.os === id);

  return (
    <section className={`${styles.section} ${dark ? `${styles.dark} on-dark` : ""}`}>
      <div className={`wrap ${styles.inner}`}>
        <div className={styles.head}>
          <div className={styles.headText}>
            <H className={styles.h2}>{heading}</H>
          </div>
          <div className={styles.headSide}>
            <p className="lede">The apps are open source and free on every platform. Your inbox lives in a local file on your own device, and like a document on your disk it opens without a connection.</p>
            {release && (
              <p className={styles.version}>
                Desktop {release.version}. Installed copies update themselves.
              </p>
            )}
          </div>
        </div>
        <div className={styles.tiles}>
          {PLATFORMS.map((p) => (
            <a key={p.id} href={installerFor(release, p.id) || p.href} className={styles.tile} target="_blank" rel="noopener">
              <OsIcon id={p.id} size={44} colored />
              <div className={styles.name}>
                <span className={styles.os}>{p.name}</span>
                <span className={styles.sub}>{build(p.id) ? `${release.version} · ${formatSize(build(p.id).size)}` : p.sub}</span>
              </div>
              <span className={styles.dl}><DownloadArrow /> Download</span>
            </a>
          ))}
        </div>
        <div className={styles.also}>
          <a href={WEB_APP_URL} target="_blank" rel="noopener"><OsIcon id="web" size={18} />Or use it in the browser at mail.inbox2.com</a>
          <a href={CLI_RELEASE_PAGE} target="_blank" rel="noopener"><OsIcon id="cli" size={18} />Or download the CLI for your terminal</a>
        </div>
      </div>
    </section>
  );
}
