import { useState } from 'react'
import TagInput from './TagInput'

export default {
  title: 'Components/TagInput',
  component: TagInput,
}

function Controlled({ initial = [], ...props }) {
  const [values, setValues] = useState(initial)
  return <TagInput values={values} onChange={setValues} {...props} />
}

export const Empty = {
  render: () => <Controlled placeholder="Add recipients…" />,
}

export const WithTags = {
  render: () => (
    <Controlled
      initial={[
        { email: 'dana@partner.com', name: 'Dana Lee' },
        { email: 'sam@inbox2.dev', name: 'Sam Okoye' },
        { email: 'ops@vendor.io' },
      ]}
      placeholder="Add recipients…"
    />
  ),
}

export const WithSuggestions = {
  render: () => (
    <Controlled
      placeholder="Type a name…"
      suggestions={[
        { email: 'dana@partner.com', name: 'Dana Lee', total: 42 },
        { email: 'darren@partner.com', name: 'Darren Ng', total: 8 },
      ]}
    />
  ),
}
