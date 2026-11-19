import { useMemo } from 'react';
import Avatar from '../Avatar';
import Icon from '../Icon';
import MgmtSparkline from '../management/MgmtSparkline';
import { ACTIVITY_METRICS } from './metrics';
import styles from './TeamActivity.module.css';

function memberName(m) {
  return m.user?.display_name || m.user?.username || m.email_addresses?.[0] || '?';
}
function memberEmail(m) {
  return m.user?.billing_email || m.email_addresses?.[0] || undefined;
}

// One teammate's card — same glass-panel language as the Spaces dashboard tiles.
// Header: avatar + name + total actions. Then a 14-day sparkline and the metrics
// written out (labelled), one row each, so it reads at a glance.
function MemberCard({ member, activity, onOpen }) {
  const totals = activity?.totals || {};
  const total = ACTIVITY_METRICS.reduce((s, mth) => s + (totals[mth.key] || 0), 0);
  const name = memberName(member);
  return (
    <button type="button" className={styles.card} onClick={() => onOpen(member.id)}>
      <div className={styles.cardHead}>
        <Avatar name={name} email={memberEmail(member)} size={42} />
        <div className={styles.who}>
          <span className={styles.name}>{name}</span>
          <span className={styles.role}>{member.role}</span>
        </div>
        <div className={styles.totalWrap}>
          <span className={styles.total}>{total}</span>
          <span className={styles.totalLabel}>actions</span>
        </div>
      </div>
      <div className={styles.sparkWrap}>
        <MgmtSparkline points={activity?.sparkline} color="#ffffff" />
      </div>
      <div className={styles.metrics}>
        {ACTIVITY_METRICS.map((mth) => (
          <div key={mth.key} className={styles.metric}>
            <span className={styles.metricIcon}><Icon name={mth.icon} size={14} /></span>
            <span className={styles.metricLabel}>{mth.label}</span>
            <span className={styles.metricNum}>{totals[mth.key] || 0}</span>
          </div>
        ))}
      </div>
    </button>
  );
}

/* The Team activity ("Toggl") board — a card per teammate with their action
 * tallies + sparkline, opening a per-member feed on click. `members` is the raw
 * org membership list (carries the mbr_ id); `activityByMember` is keyed by that
 * id. Numbers stay zero until the action paths log member-attributed events.
 * `trackingEnabled` reflects the org insights switch; `canToggle` (owner/admin)
 * gates the on/off control via `onToggle`. */
export default function TeamActivity({ members, activityByMember, loading, onOpen, trackingEnabled = true, canToggle = false, onToggle }) {
  const rows = useMemo(
    () => members.filter((m) => m.status !== 'invited'),
    [members],
  );
  const anyActivity = rows.some((m) => {
    const t = activityByMember[m.id]?.totals || {};
    return ACTIVITY_METRICS.some((mth) => (t[mth.key] || 0) > 0);
  });

  // Switched off by an owner/admin — no cards, no numbers. Admins can turn it
  // back on; everyone else sees why it's empty.
  if (!trackingEnabled) {
    return (
      <div className={styles.empty}>
        <Icon name="eye" size={22} />
        <p className={styles.emptyTitle}>Team insights are turned off</p>
        <p className={styles.emptyText}>We don’t record what members do.</p>
        {canToggle && (
          <button type="button" className={styles.toggleBtn} onClick={() => onToggle?.(true)}>Turn on insights</button>
        )}
      </div>
    );
  }

  if (!rows.length) {
    return <div className={styles.empty}>{loading ? 'Loading team…' : 'No team members yet.'}</div>;
  }

  return (
    <div className={styles.wrap}>
      <div className={styles.wrapHead}>
        {!anyActivity ? (
          <p className={styles.hint}>
            <Icon name="info.circle" size={12} /> Counts fill in as your team works the inbox.
          </p>
        ) : <span />}
        {canToggle && (
          <button type="button" className={styles.toggleBtn} onClick={() => onToggle?.(false)}>Turn off insights</button>
        )}
      </div>
      <div className={styles.grid}>
        {rows.map((m) => (
          <MemberCard key={m.id} member={m} activity={activityByMember[m.id]} onOpen={onOpen} />
        ))}
      </div>
    </div>
  );
}
