import { useState, useEffect } from 'react';
import { useNavigate, useParams } from 'react-router';
import Avatar from '../../components/Avatar';
import Icon from '../../components/Icon';
import { ACTIVITY_METRICS } from '../../components/TeamActivity/metrics';
import relativeTime from '../../lib/relativeTime';
import api from '../../lib/localFirstApi';
import log from '../../lib/log';
import styles from './MemberActivityPage.module.css';

const ICON_FOR = Object.fromEntries(ACTIVITY_METRICS.map((m) => [m.key, m.icon]));
const LABEL_FOR = Object.fromEntries(ACTIVITY_METRICS.map((m) => [m.key, m.label]));

/* A teammate's activity feed — the drill-in from a Team activity card. Streams
 * their recent actions (reply / read / archive / delete / snooze / assign) with
 * the conversation each touched. Empty until the action paths log events. */
export default function MemberActivityPage() {
  const { orgSlug, memberId } = useParams();
  const navigate = useNavigate();
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!orgSlug || !memberId) return undefined;
    let cancelled = false;
    (async () => {
      try {
        const d = await api.getMemberFeed(orgSlug, memberId);
        if (!cancelled) setData(d);
      } catch (e) {
        log.warn('MemberActivityPage', `failed: ${e?.message || e}`);
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [orgSlug, memberId]);

  const member = data?.member;
  const name = member?.user?.display_name || member?.user?.username || member?.email_addresses?.[0] || 'Teammate';
  const feed = data?.feed || [];

  return (
    <div className={styles.page}>
      <div className={styles.inner}>
      <div className={styles.head}>
        <button type="button" className={styles.back} onClick={() => navigate(`/${orgSlug}/spaces?view=team`)} aria-label="Back to team">
          <Icon name="chevron.left" size={16} />
        </button>
        <Avatar name={name} email={member?.user?.billing_email || member?.email_addresses?.[0]} size={44} />
        <div className={styles.who}>
          <h1 className={styles.name}>{name}</h1>
          <span className={styles.sub}>Activity feed</span>
        </div>
      </div>

      {loading ? (
        <div className={styles.state}>Loading activity…</div>
      ) : feed.length === 0 ? (
        <div className={styles.state}>
          <Icon name="clock" size={20} />
          <p>No activity recorded yet.</p>
        </div>
      ) : (
        <ul className={styles.feed}>
          {feed.map((e, i) => (
            <li key={i} className={styles.item}>
              <span className={styles.itemIcon}><Icon name={ICON_FOR[e.action] || 'circle.fill'} size={15} /></span>
              <span className={styles.itemBody}>
                <span className={styles.itemAction}>{LABEL_FOR[e.action] || e.action}</span>
                {e.conversation?.subject && <span className={styles.itemSubject}>{e.conversation.subject}</span>}
              </span>
              <span className={styles.itemTime}>{relativeTime(e.created_at)}</span>
            </li>
          ))}
        </ul>
      )}
      </div>
    </div>
  );
}
