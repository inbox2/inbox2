import InboxSidebar from './InboxSidebar'

const mockAccounts = [
  { key: 'org_demo', provider_type: 'inbox2', display_name: 'inbox2 Team', email_address: 'team@inbox2.dev', status: 'active' },
  { key: 'gmail_1', provider_type: 'gmail', display_name: 'Personal', email_address: 'waseem@gmail.com', status: 'active' },
]

const mockFolderViews = [
  { id: 'inbox', name: 'Inbox', icon: 'tray', count: 12 },
  { id: 'archive', name: 'Archive', icon: 'archivebox' },
  { id: 'spam', name: 'Spam', icon: 'exclamationmark.triangle', count: 3 },
  { id: 'trash', name: 'Trash', icon: 'trash' },
]

const mockSystemViews = [
  { id: 'all', name: 'All Mail', icon: 'tray.2' },
  { id: 'sent', name: 'Sent', icon: 'paperplane' },
  { id: 'drafts', name: 'Drafts', icon: 'doc.text', count: 2 },
]

const mockPersonalViews = [
  { id: 'view_1', name: 'Urgent & Unread', icon: 'flame' },
  { id: 'view_2', name: 'From VIPs', icon: 'star' },
]

const noop = () => {}

export default {
  title: 'Components/InboxSidebar',
  component: InboxSidebar,
}

export const Default = {
  args: {
    allAccounts: mockAccounts,
    activeUnifiedKey: null,
    onSwitchAccount: noop,
    onAddAccount: noop,
    onUnified: noop,
    onReorder: noop,
    folderViews: mockFolderViews,
    systemViews: mockSystemViews,
    personalViews: mockPersonalViews,
    activeView: mockFolderViews[0],
    onSwitchView: noop,
    activeAccountKey: 'org_demo',
    tags: ['planning', 'support', 'billing', 'urgent'],
    syncFolders: [],
    onNavigateSettings: noop,
    syncStatus: 'connected',
    activeAccount: mockAccounts[0],
    onOpenConsole: noop,
  },
}

export const NoViews = {
  args: {
    allAccounts: mockAccounts,
    activeUnifiedKey: null,
    onSwitchAccount: noop,
    onAddAccount: noop,
    onUnified: noop,
    onReorder: noop,
    folderViews: mockFolderViews,
    systemViews: mockSystemViews,
    personalViews: [],
    activeView: mockFolderViews[0],
    onSwitchView: noop,
    activeAccountKey: 'org_demo',
    tags: [],
    syncFolders: [],
    onNavigateSettings: noop,
    syncStatus: 'connected',
    activeAccount: mockAccounts[0],
    onOpenConsole: noop,
  },
}
