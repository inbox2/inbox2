import QuickActions from './QuickActions'

const noop = () => {}

export default {
  title: 'Components/QuickActions',
  component: QuickActions,
}

export const Unread = {
  args: {
    unread: true,
    onForward: noop,
    onMarkRead: noop,
    onArchive: noop,
    onTrash: noop,
  },
}

export const Read = {
  args: {
    unread: false,
    onForward: noop,
    onMarkRead: noop,
    onArchive: noop,
    onTrash: noop,
  },
}

export const ArchiveOnly = {
  args: {
    unread: false,
    onArchive: noop,
  },
}
