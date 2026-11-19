import MessageActions from './MessageActions'

export default {
  title: 'Components/MessageActions',
  component: MessageActions,
}

export const Default = {
  args: {
    items: [
      { label: 'Reply', icon: 'arrowshape.turn.up.left', onSelect: () => {} },
      { label: 'Reply All', icon: 'arrowshape.turn.up.left.2', onSelect: () => {} },
      { label: 'Forward', icon: 'arrowshape.turn.up.right', onSelect: () => {} },
      { separator: true },
      { label: 'View details', icon: 'info.circle', onSelect: () => {} },
      { label: 'View source', icon: 'doc.text', onSelect: () => {} },
      { separator: true },
      { label: 'Archive', icon: 'archivebox', onSelect: () => {} },
      { label: 'Mark as spam', icon: 'exclamationmark.triangle', onSelect: () => {} },
      { label: 'Move to trash', icon: 'trash', onSelect: () => {} },
    ],
  },
}
