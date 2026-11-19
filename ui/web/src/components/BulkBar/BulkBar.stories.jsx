import { useState } from 'react'
import '../../styles/management.css'
import BulkBar from './BulkBar'
import { MgmtButton } from '../management'

export default {
  title: 'Disk/BulkBar',
  component: BulkBar,
}

const actions = [
  { label: 'Download', icon: 'download', primary: true, onSelect: () => {} },
  { label: 'Move', icon: 'move', onSelect: () => {} },
  { label: 'Share', icon: 'share', onSelect: () => {} },
  { label: 'Delete', icon: 'trash', danger: true, onSelect: () => {} },
]

function Demo() {
  const [count, setCount] = useState(3)
  return (
    <div className="management">
      <BulkBar count={count} actions={actions} onClear={() => setCount(0)} />
      {!count && <MgmtButton size="sm" onClick={() => setCount(3)}>Select three</MgmtButton>}
    </div>
  )
}

export const Default = { render: () => <Demo /> }
