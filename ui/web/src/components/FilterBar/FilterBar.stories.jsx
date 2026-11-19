import { useState } from 'react'
import '../../styles/management.css'
import FilterBar from './FilterBar'
import { EMPTY_FILTERS, matchesFilters, sortNodes } from '../../lib/disk/listing'
import styles from './FilterBar.stories.module.css'

export default {
  title: 'Disk/FilterBar',
  component: FilterBar,
}

const people = [{ id: 'u1', name: 'Sara Koch' }, { id: 'u2', name: 'Jonas Lind' }]
const day = 86_400_000
const at = (days) => new Date(Date.now() - days * day).toISOString()
const nodes = [
  { id: '1', kind: 'folder', name: 'Press kit', content_modified_at: at(1), modified_by: people[0] },
  { id: '2', kind: 'file', name: 'teaser.mp4', size_bytes: 84e6, content_modified_at: at(2), modified_by: people[1] },
  { id: '3', kind: 'file', name: 'podcast-ep12.mp3', size_bytes: 31e6, content_modified_at: at(9), modified_by: people[0] },
  { id: '4', kind: 'file', name: 'Brand guidelines.pdf', size_bytes: 4e6, content_modified_at: at(5), modified_by: people[0] },
  { id: '5', kind: 'page', name: 'Launch playbook', size_bytes: 0, content_modified_at: at(0), modified_by: people[1] },
  { id: '6', kind: 'file', name: 'Budget 2026.xlsx', size_bytes: 88e3, sealed: true, content_modified_at: at(2), modified_by: people[1] },
]

function Demo() {
  const [value, setValue] = useState({ ...EMPTY_FILTERS, sort: 'name', dir: 1, view: 'list' })
  const shown = sortNodes(nodes.filter((n) => matchesFilters(n, value)), value.sort, value.dir)
  return (
    <div className={`management ${styles.page}`}>
      <FilterBar value={value} onChange={setValue} people={people} placeholder="Search in Marketing" />
      <ul className={styles.list}>{shown.map((n) => <li key={n.id}>{n.name}</li>)}</ul>
      <p className={styles.count}>{shown.length} of {nodes.length} items</p>
    </div>
  )
}

export const Default = { render: () => <Demo /> }
