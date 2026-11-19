import { Mark } from "../Mark/Mark.jsx";
import styles from "./ConsoleSection.module.css";

const NAV = [
  ["Home", <><rect x="3" y="3" width="7" height="7" rx="1.5" /><rect x="14" y="3" width="7" height="7" rx="1.5" /><rect x="3" y="14" width="7" height="7" rx="1.5" /><rect x="14" y="14" width="7" height="7" rx="1.5" /></>, true],
  ["Domains", <><circle cx="12" cy="12" r="9" /><path d="M3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18" /></>, false, 1],
  ["People", <><circle cx="9" cy="8" r="3.5" /><path d="M2.5 20c0-3.5 3-6 6.5-6s6.5 2.5 6.5 6" /><circle cx="17" cy="9" r="2.5" /><path d="M15.5 14.5c3 0 6 2 6 5.5" /></>],
  ["Routing rules", <><path d="M6 3v6c0 3 3 4 6 4s6 1 6 4v4M6 21V9" /><path d="M15 18l3 3 3-3M3 6l3-3 3 3" /></>],
];
const NAV_ACCOUNT = [
  ["Billing & plan", <><rect x="2" y="5" width="20" height="14" rx="2.5" /><path d="M2 10h20" /></>],
  ["API keys & devices", <><circle cx="8" cy="12" r="4" /><path d="M12 12h9M18 12v3M15 12v2" /></>],
  ["Applications", <><rect x="3" y="4" width="18" height="16" rx="2.5" /><path d="M3 9h18" /></>],
  ["Get the apps", <><path d="M12 3v10M8 9l4 4 4-4" /><path d="M4 15v3a2 2 0 002 2h12a2 2 0 002-2v-3" /></>],
];

function NavItem({ label, icon, on, count }) {
  return (
    <div className={`${styles.nav} ${on ? styles.on : ""}`}>
      <svg viewBox="0 0 24 24">{icon}</svg>
      {label}
      {count && <span className={styles.cnt}>{count}</span>}
    </div>
  );
}

function Spark({ d, id }) {
  return (
    <svg viewBox="0 0 100 30" preserveAspectRatio="none" className={styles.spark}>
      <defs>
        <linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#17509f" stopOpacity="0.25" />
          <stop offset="1" stopColor="#17509f" stopOpacity="0" />
        </linearGradient>
      </defs>
      <path d={`${d} V30 H0 Z`} fill={`url(#${id})`} />
      <path d={d} fill="none" stroke="#17509f" strokeWidth="1.5" />
    </svg>
  );
}

/** The console, rebuilt in markup as a browser-framed screenshot.
 *  Used full size on /mx and shrunk down in the home page's admin CTA. */
export default function ConsoleShot() {
  return (
  <div className={styles.browser}>
    <div className={styles.bar}>
      <i /><i /><i />
      <div className={styles.url}>
        <svg viewBox="0 0 16 16" width="11" height="11"><rect x="3" y="7" width="10" height="7" rx="1.5" fill="none" stroke="#5b6178" strokeWidth="1.4" /><path d="M5.5 7V5a2.5 2.5 0 015 0v2" fill="none" stroke="#5b6178" strokeWidth="1.4" /></svg>
        <b>mail.inbox2.com</b>/console
      </div>
    </div>

    <div className={styles.cs}>
      <aside className={styles.side}>
        <div className={styles.brand}><span className={styles.mk}><Mark size={18} /></span><span className={styles.wd}>inbox2</span><span className={styles.kk}>Console</span></div>
        {NAV.map(([l, ic, on, c]) => <NavItem key={l} label={l} icon={ic} on={on} count={c} />)}
        <div className={styles.grp}>Account</div>
        {NAV_ACCOUNT.map(([l, ic]) => <NavItem key={l} label={l} icon={ic} />)}
        <div className={styles.sp} />
        <div className={`${styles.nav} ${styles.center}`}>Open mail ↗</div>
        <div className={styles.user}><span className={styles.av}>SV</span><span><span className={styles.nm}>Sara Vos</span><span className={styles.em}>yourcompany.com</span></span></div>
      </aside>

      <div className={styles.main}>
        <div className={styles.ph}>
          <div>
            <div className={styles.eyebrow}>yourcompany.com &amp; 1 more domain</div>
            <h3 className={styles.title}>Good afternoon, Sara.</h3>
            <p className={styles.sub}>Mail is flowing on 1 of 2 domains. 2 things need your attention.</p>
          </div>
          <div className={styles.pa}><span className={styles.mb}>＋ Invite people</span><span className={`${styles.mb} ${styles.pri}`}>＋ Add domain</span></div>
        </div>
        <div className={styles.stats}>
          <div className={`${styles.card} ${styles.stat}`}><div className={styles.sh}>Inbound <span className={styles.delta}>▲ 12%</span></div><span className={styles.num}>4,812</span><span className={styles.ss}>last 7 days</span><div className={styles.sb}><Spark id="sg1" d="M0 22 L14 18 L28 20 L42 12 L56 15 L70 9 L84 11 L100 4" /></div></div>
          <div className={`${styles.card} ${styles.stat}`}><div className={styles.sh}>Outbound <span className={styles.delta}>▲ 4%</span></div><span className={styles.num}>1,206</span><span className={styles.ss}>last 7 days</span><div className={styles.sb}><Spark id="sg2" d="M0 16 L14 19 L28 14 L42 17 L56 13 L70 15 L84 10 L100 12" /></div></div>
          <div className={`${styles.card} ${styles.stat}`}><div className={styles.sh}>Spam blocked</div><span className={styles.num}>918</span><span className={styles.ss}>96% caught before the pool</span><div className={styles.sb}><div className={styles.meter}><i className={styles.m96} /></div></div></div>
          <div className={`${styles.card} ${styles.stat}`}><div className={styles.sh}>AI triage</div><span className={styles.num}>83%</span><span className={styles.ss}>auto-filed into Spaces</span><span className={styles.cta}>41 unrouted in Triage ↗</span><div className={styles.sb}><div className={styles.meter}><i className={styles.m83} /></div></div></div>
        </div>
        <div className={styles.g2}>
          <div className={styles.card}>
            <div className={styles.ch}><h4>Domain health</h4><span className={styles.fakeLink}>All domains →</span></div>
            <table className={styles.tbl}>
              <thead><tr><th>Domain</th><th>DNS</th><th className={styles.r}>Users</th><th /></tr></thead>
              <tbody>
                <tr><td><span className={styles.dom}><span className={`${styles.fav} ${styles.favInk}`}>YC</span>yourcompany.com</span></td><td><span className={styles.dns}><span>MX</span><span>SPF</span><span>DKIM</span><span>DMARC</span></span></td><td className={styles.r}>14</td><td className={styles.r}><span className={`${styles.st} ${styles.ok}`}>Receiving</span></td></tr>
                <tr><td><span className={styles.dom}><span className={`${styles.fav} ${styles.favOffset}`}>SU</span>support-yourcompany.eu</span></td><td><span className={styles.dns}><span>MX</span><span className={styles.bad}>SPF</span><span className={styles.bad}>DKIM</span><span className={styles.na}>DMARC</span></span></td><td className={styles.r}>3</td><td className={styles.r}><span className={`${styles.st} ${styles.warn}`}>Pending DNS</span></td></tr>
              </tbody>
            </table>
          </div>
          <div className={styles.card}>
            <div className={styles.ch}><h4>Needs attention</h4></div>
            <ul className={styles.attn}>
              <li><i /><div><b>support-yourcompany.eu isn’t receiving mail</b><span>DNS records are still missing at your provider.</span><span className={styles.fakeLink}>Finish setup →</span></div></li>
              <li><i className={styles.info} /><div><b>41 conversations unrouted in Triage</b><span>No rule or Space matched them.</span><span className={styles.fakeLink}>Review rules →</span></div></li>
            </ul>
          </div>
        </div>
      </div>
    </div>
  </div>
  );
}
