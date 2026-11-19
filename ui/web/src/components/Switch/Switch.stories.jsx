import { useState } from 'react'
import Switch from './Switch'

export default {
  title: 'Components/Switch',
  component: Switch,
}

function Controlled({ initial = false, ...props }) {
  const [checked, setChecked] = useState(initial)
  return <Switch checked={checked} onChange={setChecked} {...props} />
}

export const Off = {
  render: () => <Controlled id="sw-off" label="Show remote images" />,
}

export const On = {
  render: () => <Controlled id="sw-on" initial label="Show remote images" />,
}

export const WithDescription = {
  render: () => (
    <Controlled
      id="sw-desc"
      initial
      label="Notifications"
      description="Get a desktop alert when new mail arrives in this view."
    />
  ),
}

export const Disabled = {
  render: () => (
    <Switch id="sw-disabled" label="Sync over cellular" checked={false} disabled onChange={() => {}} />
  ),
}
