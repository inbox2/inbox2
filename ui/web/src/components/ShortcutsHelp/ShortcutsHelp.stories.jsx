import ShortcutsHelp from './ShortcutsHelp'

const noop = () => {}

export default {
  title: 'Components/ShortcutsHelp',
  component: ShortcutsHelp,
}

// Content comes from the lib/shortcuts registry (single source of truth), so the
// only state that matters is open/closed.
export const Default = {
  args: {
    open: true,
    onClose: noop,
  },
}
