import Icon from '../Icon';
import useCopyToClipboard from '../../hooks/useCopyToClipboard';
import styles from './DnsRecordsTable.module.css';

// The apex domain is the bare root that the MX/SPF records sit on — it's the
// shortest host in the set (every other host is a subdomain of it).
function apexOf(records) {
  return records.reduce((min, r) => (r.host && r.host.length < min.length ? r.host : min), records[0]?.host || '');
}

// What to type in the DNS provider's "name/host" field. Providers want the name
// RELATIVE to the zone: the root is "@", and subdomains drop the apex suffix.
function recordName(host, apex) {
  if (!apex || !host) return host;
  if (host === apex) return '@';
  if (host.endsWith(`.${apex}`)) return host.slice(0, -(apex.length + 1));
  return host;
}

// A scannable table of the DNS records a customer must add to point their domain
// at inbox2 (light "management" theme — used in onboarding, the admin Verify
// modal, and the domain settings page). One source of truth so they never drift.
// Every name/value is click-to-copy (the "@" root is left as plain text).
//
// records: [{ type, host, value, priority, status }] (from DnsRecordsSerializer)
// verified: optional (record, index) => true | false | null — live check result.
//   When omitted, each record's own `status` drives the indicator.
// apex: pass it when no record sits on the root (send-only domains), else it is guessed.
export default function DnsRecordsTable({ records = [], verified, apex: apexProp }) {
  const [toast, copy] = useCopyToClipboard(1400);
  const apex = apexProp || apexOf(records);
  const hasRoot = records.some((r) => r.host === apex);

  const copyCell = (text, className) => (
    <button type="button" className={[styles.copy, className].join(' ')} onClick={() => copy(text)} title="Click to copy">
      {text}
    </button>
  );

  return (
    <>
      <div className={styles.wrap}>
        <table className={styles.table}>
          <thead>
            <tr>
              <th className={styles.thState} aria-label="Status" />
              <th>Type</th>
              <th>Priority</th>
              <th>Name</th>
              <th>Points to</th>
            </tr>
          </thead>
          <tbody>
            {records.map((r, i) => {
              const id = `${r.type}-${i}`;
              const name = recordName(r.host, apex);
              const ok = verified ? verified(r, i) : (r.status === 'verified' ? true : null);
              return (
                <tr key={id}>
                  <td className={styles.cellState}>
                    {ok === true ? (
                      <Icon name="checkmark.circle.fill" size={17} className={styles.ok} />
                    ) : ok === false ? (
                      <Icon name="xmark.circle.fill" size={17} className={styles.bad} />
                    ) : (
                      <span className={styles.pendingDot} />
                    )}
                  </td>
                  <td><span className={styles.type}>{r.type}</span></td>
                  <td className={styles.priority}>{r.priority ?? '—'}</td>
                  <td>
                    {name === '@'
                      ? <code className={styles.root} title={r.host}>@</code>
                      : copyCell(name, styles.name)}
                  </td>
                  <td>{copyCell(r.value, styles.value)}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      {hasRoot && (
        <p className={styles.hint}>
          <code className={styles.root}>@</code> is your domain&rsquo;s root. Enter <code>@</code> or <code>{apex}</code>,
          whichever your DNS provider uses. Enter other names without your domain on the end.
        </p>
      )}
      {toast && (
        <div className={styles.toast} role="status">
          <Icon name="checkmark.circle.fill" size={14} /> Copied to clipboard
        </div>
      )}
    </>
  );
}
