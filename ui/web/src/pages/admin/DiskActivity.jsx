import { useEffect, useState } from 'react'
import { MgmtButton, MgmtSelect } from '../../components/management'
import DateField from '../../components/DateField/DateField'
import Skeleton from '../../components/Skeleton'
import diskApi, { localZone } from '../../lib/disk/api'
import { EVENT_TEXT } from '../../lib/disk/model'
import styles from './console.module.css'
import own from './ConsoleDisk.module.css'

const NO_FILTERS = { share: '', member: '', type: '', from: '', to: '' }
const ACTIONS = Object.keys(EVENT_TEXT).sort().map((a) => ({ value: a, label: EVENT_TEXT[a].replace(/ it$/, '') }))

const who = (e) => (e.link_id && !e.actor ? 'A visitor' : e.actor ? `${e.actor.name}${e.actor.agent ? ' (agent)' : ''}` : 'Someone')
const what = (e) => (!e.item ? '' : e.item.sealed ? `Sealed ${e.item.kind}` : e.item.name || '')

/* The console's org-wide Disk activity (spec F11): every share's events and
   every member's, filtered by share, person, action and dates, a page at a time.
   Agents are named as agents; sealed items have no name. Owners and admins only. */
export default function DiskActivity({ orgId, shares, members }) {
  const [filters, setFilters] = useState(NO_FILTERS)
  const [events, setEvents] = useState(null)
  const [cursor, setCursor] = useState(null)
  const [error, setError] = useState(null)

  useEffect(() => {
    let live = true
    diskApi.adminEvents(orgId, { ...filters, tz: localZone() })
      .then((d) => { if (live) { setEvents(d.events); setCursor(d.next_cursor); setError(null) } })
      .catch((e) => { if (live) { setEvents([]); setError(e) } })
    return () => { live = false }
  }, [orgId, filters])

  // A filter change shows the skeleton until its first page lands.
  const filter = (next) => { setEvents(null); setCursor(null); setFilters(next) }
  const set = (k) => (v) => filter({ ...filters, [k]: v?.target ? v.target.value : v })
  const more = () => diskApi.adminEvents(orgId, { ...filters, tz: localZone() }, cursor)
    .then((d) => { setEvents((all) => [...all, ...d.events]); setCursor(d.next_cursor) }).catch(setError)
  const filtered = Object.values(filters).some(Boolean)

  return (
    <div className={`${styles.card} ${styles.mt}`} aria-busy={events === null}>
      <div className={styles.cardHead}><h2 className={styles.cardTitle}>Activity</h2></div>
      <div className={`${own.pad} ${own.filters}`}>
        <MgmtSelect bare compact aria-label="Share" value={filters.share} onChange={set('share')}
          options={[{ value: '', label: 'All shares' }, ...shares.map((r) => ({ value: r.share.id, label: r.share.name }))]} />
        <MgmtSelect bare compact aria-label="Person" value={filters.member} onChange={set('member')}
          options={[{ value: '', label: 'Everyone' }, ...members.map((r) => ({ value: r.member.id, label: `${r.member.name}${r.member.agent ? ' (agent)' : ''}` }))]} />
        <MgmtSelect bare compact aria-label="Action" value={filters.type} onChange={set('type')}
          options={[{ value: '', label: 'Every action' }, ...ACTIONS]} />
        <DateField value={filters.from} onChange={set('from')} aria-label="From" placeholder="From" className={own.dateField} />
        <DateField value={filters.to} onChange={set('to')} min={filters.from} aria-label="To" placeholder="To" className={own.dateField} />
        {filtered && <MgmtButton size="sm" variant="glass" onClick={() => filter(NO_FILTERS)}>Clear filters</MgmtButton>}
      </div>
      {error && <p className={`${own.error} ${own.pad}`} role="alert">{error.message}</p>}
      {events === null ? <Skeleton variant="text" count={6} className={own.tableSkeleton} /> : !events.length ? (
        <p className={`${own.muted} ${own.pad}`}>{filtered ? 'No activity matches these filters.' : 'No activity yet.'}</p>
      ) : (
        <table className={styles.tbl}>
          <thead><tr><th>Time</th><th>Person</th><th>Action</th><th>Item</th><th>Share</th></tr></thead>
          <tbody>
            {events.map((e) => (
              <tr key={e.id}>
                <td className={styles.num}>{new Date(e.created_at).toLocaleString()}</td>
                <td>{who(e)}</td>
                <td>{EVENT_TEXT[e.action] || e.action.replace(/_/g, ' ')}</td>
                <td>{what(e)}</td>
                <td>{e.share_name || (e.item ? 'C:\\' : '')}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {cursor && events && <div className={own.pad}><MgmtButton size="sm" variant="glass" onClick={more}>Show more</MgmtButton></div>}
    </div>
  )
}
