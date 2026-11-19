import { useState } from 'react'
import '../../styles/management.css'
import Breadcrumbs from './Breadcrumbs'
import { pathSegments } from '../../lib/disk/paths'
import styles from './Breadcrumbs.stories.module.css'

export default {
  title: 'Disk/Breadcrumbs',
  component: Breadcrumbs,
}

const deep = pathSegments('D', [
  { id: 's', name: 'Marketing', sealed: false },
  { id: 'a', name: 'Launch 2026', sealed: false },
  { id: 'b', name: 'Press kit', sealed: false },
  { id: 'c', name: null, sealed: true },
  { id: 'd', name: 'Photos', sealed: false },
], { c: 'Embargoed' })

function Demo({ initial }) {
  const [segments, setSegments] = useState(initial)
  return (
    <div className="management">
      <Breadcrumbs segments={segments} onNavigate={(_, i) => setSegments(segments.slice(0, i + 1))} />
    </div>
  )
}

export const MyDisk = {
  render: () => <Demo initial={pathSegments('C', [{ id: 'r', name: null }, { id: 'p', name: 'Projects' }, { id: 'q', name: 'Q4' }])} />,
}

export const DeepShare = { render: () => <Demo initial={deep} /> }

export const NarrowCollapses = {
  render: () => <div className={styles.narrow}><Demo initial={deep} /></div>,
}
