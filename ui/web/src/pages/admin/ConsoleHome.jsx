import { useState } from 'react';
import { useNavigate, Link } from 'react-router';
import Icon from '../../components/Icon';
import Spinner from '../../components/Spinner';
import useAuth from '../../hooks/useAuth';
import useAdminData from '../../hooks/useAdminData';
import useBilling from '../../hooks/useBilling';
import InviteMxModal from './InviteMxModal';
import { MgmtButton, MgmtDelta, MgmtMeter, MgmtSparkline } from '../../components/management';
import { fmt } from '../../lib/format';
import { initialsDataUri } from '../../lib/initialsIcon';
import styles from './console.module.css';
import { consolePath } from '../../lib/consoleHost';

/* Console Home — the summary before the detail: mail-flow stats, per-domain
 * DNS health, and a "Needs attention" list that surfaces what's actually
 * broken (pending DNS, unrouted triage backlog) instead of a wall of green. */

const DNS_RECORDS = [
  { label: 'MX', key: 'mx' },
  { label: 'SPF', key: 'spf' },
  { label: 'DKIM', key: 'dkim' },
  { label: 'DMARC', key: 'dmarc' },
];

function greeting() {
  const h = new Date().getHours();
  if (h < 6) return 'Working late';
  if (h < 12) return 'Good morning';
  if (h < 18) return 'Good afternoon';
  return 'Good evening';
}

export default function ConsoleHome() {
  const navigate = useNavigate();
  const { user, organizations, currentOrg } = useAuth();
  const { domains, stats, loading, refresh } = useAdminData(organizations);
  const [inviteOpen, setInviteOpen] = useState(false);

  const billingOrgId = currentOrg?.id || organizations?.[0]?.id;
  const { atDomainLimit } = useBilling(billingOrgId, domains.length, refresh);

  const receiving = domains.filter((d) => d.status !== 'pending').length;
  const pending = domains.filter((d) => d.status === 'pending');
  const pctText = (r) => (r == null ? '—' : `${Math.round(r * 100)}%`);
  const firstName = (user?.display_name || user?.username || '').split(' ')[0];

  const attention = [
    ...pending.map((d) => ({
      key: `dns-${d.key}`,
      tone: styles.attnWarn,
      title: `${d.name} isn’t receiving mail`,
      sub: 'DNS records are still missing at your provider.',
      cta: 'Finish setup →',
      go: () => navigate(consolePath(`domains/${d.domainSlug || d.slug}?tab=dns`)),
    })),
    ...(stats.unrouted > 0 ? [{
      key: 'triage',
      tone: styles.attnInfo,
      title: `${fmt(stats.unrouted)} conversations waiting in Triage`,
      sub: 'No rule or Space matched them.',
      cta: 'Review rules →',
      go: () => navigate(consolePath('rules')),
    }] : []),
  ];

  return (
    <>
      <div className={styles.pageHead}>
        <div>
          <div className={styles.pageEyebrow}>
            {domains.length > 0
              ? `${domains[0].name}${domains.length > 1 ? ` & ${domains.length - 1} more domain${domains.length > 2 ? 's' : ''}` : ''}`
              : "Your domain's inbox"}
          </div>
          <h1 className={styles.pageTitle}>{greeting()}{firstName ? `, ${firstName}` : ''}.</h1>
          <p className={styles.pageSub}>
            {loading
              ? 'Loading your domains…'
              : domains.length === 0
                ? 'Connect your domain to get all its mail in one team inbox.'
                : `${receiving} of ${domains.length} domain${domains.length === 1 ? '' : 's'} receiving mail.${attention.length ? ` ${attention.length} thing${attention.length === 1 ? '' : 's'} need${attention.length === 1 ? 's' : ''} your attention.` : ''}`}
          </p>
        </div>
        <div className={styles.pageActions}>
          {domains.length > 0 && (
            <MgmtButton variant="glass" onClick={() => setInviteOpen(true)}>
              <Icon name="person.badge.plus" size={14} /> Invite people
            </MgmtButton>
          )}
          <MgmtButton
            variant="primary"
            onClick={() => (atDomainLimit ? navigate(consolePath('billing')) : navigate('/onboarding'))}
          >
            <Icon name={atDomainLimit ? 'sparkles' : 'plus'} size={14} />
            {atDomainLimit ? 'Upgrade to add domains' : 'Add domain'}
          </MgmtButton>
        </div>
      </div>

      {loading ? (
        <div className={`${styles.card} ${styles.cardLoading}`}><Spinner size={18} color="#2f7ad6" /></div>
      ) : (
        <div className={styles.statGrid}>
          <div className={`${styles.card} ${styles.stat}`}>
            <div className={styles.statHead}>Inbound <MgmtDelta value={stats.inboundDelta} /></div>
            <span className={styles.statNum}>{fmt(stats.inbound7d)}</span>
            <span className={styles.statSub}>last 7 days</span>
            <div className={styles.statBottom}><MgmtSparkline id="inSpark" points={stats.inboundSeries} /></div>
          </div>
          <div className={`${styles.card} ${styles.stat}`}>
            <div className={styles.statHead}>Outbound <MgmtDelta value={stats.outboundDelta} /></div>
            <span className={styles.statNum}>{fmt(stats.outbound7d)}</span>
            <span className={styles.statSub}>last 7 days</span>
            <div className={styles.statBottom}><MgmtSparkline id="outSpark" points={stats.outboundSeries} /></div>
          </div>
          <div className={`${styles.card} ${styles.stat}`}>
            <div className={styles.statHead}>Spam blocked</div>
            <span className={styles.statNum}>{fmt(stats.spamBlocked)}</span>
            <span className={styles.statSub}>{pctText(stats.spamCaughtRate)} caught before the inbox</span>
            <div className={styles.statBottom}><MgmtMeter value={stats.spamCaughtRate} /></div>
          </div>
          <div className={`${styles.card} ${styles.stat}`}>
            <div className={styles.statHead}>AI triage</div>
            <span className={styles.statNum}>{pctText(stats.coverage)}</span>
            <span className={styles.statSub}>filed into Spaces</span>
            {stats.unrouted > 0 && (
              <button type="button" className={styles.statCta} onClick={() => navigate('/spaces')}>
                {fmt(stats.unrouted)} waiting in Triage <Icon name="arrow.up.right" size={11} />
              </button>
            )}
            <div className={styles.statBottom}><MgmtMeter value={stats.coverage} /></div>
          </div>
        </div>
      )}

      <div className={styles.grid2}>
        <div className={styles.card}>
          <div className={styles.cardHead}>
            <h2 className={styles.cardTitle}>Domain health</h2>
            <Link className={styles.cardMore} to={consolePath('domains')}>All domains →</Link>
          </div>
          {loading ? (
            <div className={styles.cardLoading}><Spinner size={16} color="#2f7ad6" /></div>
          ) : domains.length === 0 ? (
            <div className={styles.attnEmpty}>No domains connected yet.</div>
          ) : (
            <table className={styles.tbl}>
              <thead>
                <tr><th>Domain</th><th>DNS</th><th className={styles.right}>Users</th><th></th></tr>
              </thead>
              <tbody>
                {domains.map((d) => (
                  <tr
                    key={d.key}
                    className={styles.rowLink}
                    onClick={() => navigate(consolePath(`domains/${d.domainSlug || d.slug}`))}
                  >
                    <td>
                      <span className={styles.domainCell}>
                        <img className={styles.favicon} src={d.iconUrl || initialsDataUri(d.name)} alt="" />
                        {d.name}
                      </span>
                    </td>
                    <td>
                      <span className={styles.dnsMarks}>
                        {DNS_RECORDS.map(({ label, key }) => {
                          const state = d.dnsChecks?.[key];
                          const cls = state === true ? styles.dnsMarkOk : state === false ? styles.dnsMarkBad : styles.dnsMarkNa;
                          const status = state === true ? 'live' : state === false ? 'missing' : 'not checked';
                          return <span key={label} className={`${styles.dnsMark} ${cls}`} title={`${label}: ${status}`}>{label}</span>;
                        })}
                      </span>
                    </td>
                    <td className={`${styles.right} ${styles.num}`}>{fmt(d.users)}</td>
                    <td className={styles.right}>
                      <span className={d.status === 'pending' ? `${styles.pill} ${styles.pillWarn}` : `${styles.pill} ${styles.pillOk}`}>
                        {d.status === 'pending' ? 'Pending DNS' : 'Receiving'}
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>

        <div className={styles.card}>
          <div className={styles.cardHead}><h2 className={styles.cardTitle}>Needs attention</h2></div>
          {attention.length === 0 ? (
            <div className={styles.attnEmpty}>
              <Icon name="checkmark.circle" size={16} /> Nothing needs you right now.
            </div>
          ) : (
            <ul className={styles.attnList}>
              {attention.map((a) => (
                <li key={a.key}>
                  <span className={`${styles.attnDot} ${a.tone}`} />
                  <div>
                    <span className={styles.attnTitle}>{a.title}</span>
                    <span className={styles.attnSub}>{a.sub}</span>
                    <br />
                    <button type="button" className={styles.attnLink} onClick={a.go}>{a.cta}</button>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>

      {inviteOpen && <InviteMxModal domains={domains} onClose={() => setInviteOpen(false)} />}
    </>
  );
}
