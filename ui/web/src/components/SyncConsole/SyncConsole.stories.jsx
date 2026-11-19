import SyncConsole from './SyncConsole'

const mockAccount = {
  provider_type: 'imap',
  email_address: 'waseem@fastmail.com',
  host: 'imap.fastmail.com',
  port: 993,
  use_tls: true,
  status: 'active',
}

const mockFolders = [
  { key: 'INBOX', provider_name: 'INBOX', well_known_role: 'inbox', last_synced_uid: 4521, sync_enabled: true },
  { key: 'Sent', provider_name: 'Sent', well_known_role: 'sent', last_synced_uid: 1283, sync_enabled: true },
  { key: 'Archive', provider_name: 'Archive', well_known_role: 'archive', last_synced_uid: 892, sync_enabled: true },
  { key: 'Trash', provider_name: 'Trash', well_known_role: 'trash', last_synced_uid: 45, sync_enabled: false },
  { key: 'Drafts', provider_name: 'Drafts', well_known_role: 'drafts', last_synced_uid: 12, sync_enabled: false },
]

const mockLogs = [
  { time: new Date(Date.now() - 30000).toISOString(), level: 'info', message: 'Sync started' },
  { time: new Date(Date.now() - 28000).toISOString(), level: 'info', message: 'INBOX: starting…' },
  { time: new Date(Date.now() - 26000).toISOString(), level: 'info', message: 'INBOX: batch 1 +25 (25 total)' },
  { time: new Date(Date.now() - 22000).toISOString(), level: 'info', message: 'INBOX: batch 2 +25 (50 total)' },
  { time: new Date(Date.now() - 18000).toISOString(), level: 'info', message: 'INBOX: batch 3 +50 (100 total)' },
  { time: new Date(Date.now() - 12000).toISOString(), level: 'info', message: 'INBOX: done — 100 messages' },
  { time: new Date(Date.now() - 8000).toISOString(), level: 'info', message: 'SENT: up to date (no changes)' },
  { time: new Date(Date.now() - 5000).toISOString(), level: 'info', message: 'Sync complete — 4 folders, 100 messages in 25s' },
]

const noop = () => {}

export default {
  title: 'Components/SyncConsole',
  component: SyncConsole,
}

export const Default = {
  args: {
    open: true,
    onClose: noop,
    account: mockAccount,
    folders: mockFolders,
    syncStatus: { capabilities: ['IMAP4rev1', 'IDLE', 'NAMESPACE', 'UIDPLUS', 'MOVE', 'CONDSTORE'] },
    logs: mockLogs,
  },
}

export const Empty = {
  args: {
    open: true,
    onClose: noop,
    account: mockAccount,
    folders: [],
    syncStatus: { capabilities: [] },
    logs: [],
  },
}

export const WithError = {
  args: {
    open: true,
    onClose: noop,
    account: { ...mockAccount, status: 'error' },
    folders: mockFolders,
    syncStatus: { capabilities: [] },
    logs: [
      ...mockLogs,
      { time: new Date().toISOString(), level: 'error', message: 'Connection lost: timeout after 30s' },
    ],
  },
}
