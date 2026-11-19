import SyncStatusBar from './SyncStatusBar'

export default {
  title: 'Components/SyncStatusBar',
  component: SyncStatusBar,
}

export const Connected = {
  args: {
    status: 'connected',
    lastSyncAt: new Date(Date.now() - 30000).toISOString(),
    onOpenConsole: () => {},
    onRefresh: () => {},
    isSyncing: false,
  },
}

export const Syncing = {
  args: {
    status: 'syncing',
    lastSyncAt: new Date(Date.now() - 120000).toISOString(),
    onOpenConsole: () => {},
    onRefresh: () => {},
    isSyncing: true,
  },
}

export const Connecting = {
  args: {
    status: 'connecting',
    onOpenConsole: () => {},
    onRefresh: () => {},
    isSyncing: false,
  },
}

export const Error = {
  args: {
    status: 'error',
    lastSyncAt: new Date(Date.now() - 600000).toISOString(),
    onOpenConsole: () => {},
    onRefresh: () => {},
    isSyncing: false,
  },
}

export const Disconnected = {
  args: {
    status: 'disconnected',
    onOpenConsole: () => {},
    onRefresh: () => {},
    isSyncing: false,
  },
}
