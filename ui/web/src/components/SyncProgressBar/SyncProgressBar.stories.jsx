import SyncProgressBar from './SyncProgressBar'

export default {
  title: 'Components/SyncProgressBar',
  component: SyncProgressBar,
}

// No folderTotal → animated indeterminate sliver.
export const Indeterminate = {
  render: () => <SyncProgressBar />,
}

export const EarlyProgress = {
  render: () => (
    <SyncProgressBar
      progress={{
        folderName: 'Inbox',
        folderIndex: 1,
        totalFolders: 4,
        synced: 120,
        folderTotal: 2400,
      }}
    />
  ),
}

export const MidProgress = {
  render: () => (
    <SyncProgressBar
      progress={{
        folderName: 'Sent',
        folderIndex: 2,
        totalFolders: 4,
        synced: 600,
        folderTotal: 1200,
      }}
    />
  ),
}

export const NearlyDone = {
  render: () => (
    <SyncProgressBar
      progress={{
        folderName: 'Archive',
        folderIndex: 4,
        totalFolders: 4,
        synced: 980,
        folderTotal: 1000,
      }}
    />
  ),
}
