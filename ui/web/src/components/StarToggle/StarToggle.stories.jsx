import { useState } from 'react'
import '../../styles/management.css'
import StarToggle from './StarToggle'

export default {
  title: 'Disk/StarToggle',
  component: StarToggle,
}

function Demo() {
  const [on, setOn] = useState(false)
  return (
    <div className="management">
      <h1>Brand <StarToggle on={on} onToggle={setOn} label="Brand" /></h1>
    </div>
  )
}

export const Default = { render: () => <Demo /> }
