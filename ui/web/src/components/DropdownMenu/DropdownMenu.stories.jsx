import DropdownMenu from './DropdownMenu'

export default {
  title: 'Components/DropdownMenu',
  component: DropdownMenu,
}

export const Default = {
  args: {
    trigger: <button>Open Menu</button>,
    items: [
      { label: 'Edit', icon: 'pencil', onSelect: () => {} },
      { label: 'Duplicate', icon: 'doc.on.doc', onSelect: () => {} },
      { separator: true },
      { label: 'Archive', icon: 'archivebox', onSelect: () => {} },
      { label: 'Delete', icon: 'trash', onSelect: () => {} },
    ],
  },
}

export const WithActiveValue = {
  args: {
    trigger: <button>Sort by</button>,
    value: 'date',
    items: [
      { label: 'Date', value: 'date', onSelect: () => {} },
      { label: 'Sender', value: 'sender', onSelect: () => {} },
      { label: 'Subject', value: 'subject', onSelect: () => {} },
    ],
  },
}

export const WithSubmenu = {
  args: {
    trigger: <button>Actions</button>,
    items: [
      { label: 'Move to', icon: 'folder', submenu: [
        { label: 'Inbox', onSelect: () => {} },
        { label: 'Archive', onSelect: () => {} },
        { label: 'Spam', onSelect: () => {} },
      ]},
      { separator: true },
      { label: 'Delete', icon: 'trash', onSelect: () => {} },
    ],
  },
}

export const AlignRight = {
  args: {
    trigger: <button>Menu</button>,
    align: 'right',
    items: [
      { label: 'Settings', icon: 'gear', onSelect: () => {} },
      { label: 'Help', icon: 'questionmark.circle', onSelect: () => {} },
    ],
  },
}
