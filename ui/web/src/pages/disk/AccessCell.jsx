import { useState } from 'react'
import Avatar from '../../components/Avatar'
import Skeleton from '../../components/Skeleton'
import diskApi from '../../lib/disk/api'
import { ROLE_LABEL, OPENNESS, openTo } from '../../lib/disk/model'
import styles from './AccessCell.module.css'

// Share members per share id, fetched once per session for the popovers.
// ponytail: never refreshed until reload; invalidate on member edits if it misleads.
const shareMembersCache = new Map()

/**
 * The Access column (mockup: .who / .avs / .inh / .pop). The listing's
 * `shared_with` gives the people with their own grant on the row (avatars,
 * first few, plus a count) and whether access is also inherited; with no
 * grants it is a dashed "inherits" link, or "only you" on C:\. Hover or focus
 * lists who has access and where it comes from; only the share's members are
 * fetched, on first hover.
 *
 *   node    the row (node.shared_with: { people, total, inherited })
 *   orgId, share (the folder's share or null), where (the folder's DOS path)
 */
export default function AccessCell({ node, orgId, share, where }) {
  const [members, setMembers] = useState(null)
  const sw = node.shared_with || { people: [], total: 0, inherited: !!share }
  const inheritsShare = share && sw.inherited

  const load = () => {
    if (!inheritsShare || members) return
    if (!shareMembersCache.has(share.id)) {
      shareMembersCache.set(share.id, diskApi.shareMembers(orgId, share.id).then((d) => d.members).catch(() => []))
    }
    setMembers('loading')
    shareMembersCache.get(share.id).then(setMembers)
  }

  const more = sw.total - sw.people.length
  return (
    <span className={styles.who} tabIndex={0} role="presentation" data-access onMouseEnter={load} onFocus={load}>
      {sw.total > 0 ? (
        <span className={styles.avs} aria-label={`Shared with ${sw.total} ${sw.total === 1 ? 'person' : 'people'}`}>
          {sw.people.map((p) => <span key={p.membership_id} className={styles.av}><Avatar name={p.name} src={p.avatar_url} size={24} /></span>)}
          {more > 0 && <span className={styles.more}>+{more}</span>}
        </span>
      ) : (
        <span className={sw.inherited ? styles.inh : styles.only}>{sw.inherited ? 'same as folder' : 'only you'}</span>
      )}
      <span className={styles.pop} role="tooltip">
        {sw.total > 0 && <b className={styles.from}>Shared with {sw.total} {sw.total === 1 ? 'person' : 'people'}</b>}
        {sw.people.map((p) => (
          <span key={p.membership_id} className={styles.line}><Avatar name={p.name} src={p.avatar_url} size={20} />{p.name}<i>{ROLE_LABEL[p.role]}</i></span>
        ))}
        {more > 0 && <span className={styles.line}>and {more} more</span>}
        {sw.inherited && <b className={styles.from}>{sw.total ? 'Also from' : 'Same as'} {where}</b>}
        {inheritsShare && share.openness === OPENNESS.ORG && <span className={styles.line}>{openTo(share)}<i>{ROLE_LABEL[share.org_role]}</i></span>}
        {members === 'loading' && <Skeleton variant="text" count={2} />}
        {Array.isArray(members) && members.map((m) => (
          <span key={m.membership_id} className={styles.line}>{m.name}<i>{ROLE_LABEL[m.role]}</i></span>
        ))}
        {node.sealed && <span className={styles.line}>Sealed: only key holders can open it.</span>}
        {!sw.total && !sw.inherited && <span className={styles.line}>Only you can open this.</span>}
      </span>
    </span>
  )
}
