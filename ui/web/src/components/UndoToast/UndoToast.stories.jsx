import UndoToast from './UndoToast'

export default {
  title: 'Components/UndoToast',
  component: UndoToast,
}

export const SingleEntry = {
  args: {
    entries: [{ id: '1', description: 'Archived "Q3 planning sync"', variant: 'triage', icon: 'archivebox' }],
    onUndo: () => {},
    onDismiss: () => {},
  },
}

export const TriageVariant = {
  args: {
    entries: [{ id: '1', description: 'Moved to Priority', variant: 'triage', icon: 'flame.fill' }],
    onUndo: () => {},
    onDismiss: () => {},
  },
}

export const MultipleEntries = {
  args: {
    entries: [
      { id: '1', description: 'Archived "Q3 planning sync"', variant: 'triage', icon: 'archivebox' },
      { id: '2', description: 'Deleted "Spam offer"', variant: 'danger', icon: 'trash' },
      { id: '3', description: 'Moved to Priority', variant: 'triage', icon: 'flame.fill' },
    ],
    onUndo: () => {},
    onDismiss: () => {},
  },
}

export const Empty = {
  args: {
    entries: [],
    onUndo: () => {},
    onDismiss: () => {},
  },
}
