import '../../styles/management.css'
import UploadPanel from './UploadPanel'
import useUploadStore, { UPLOAD_STATE as S } from '../../stores/uploadStore'

export default {
  title: 'Disk/UploadPanel',
  component: UploadPanel,
}

const GB = 1024 ** 3
const items = [
  { id: '1', name: 'teaser-cut4.mp4', relativePath: 'teaser-cut4.mp4', size: 1.4 * GB, loaded: 0.62 * GB, state: S.RUNNING },
  { id: '2', name: 'hero.png', relativePath: 'Press kit/hero.png', size: 2_400_000, loaded: 0, state: S.QUEUED },
  { id: '3', name: 'Q4 plan.docx', relativePath: 'Q4 plan.docx', size: 212_000, loaded: 0, state: S.CONFLICT, error: 'An item named "Q4 plan.docx" already exists here' },
  { id: '4', name: 'old.mov', relativePath: 'old.mov', size: 3 * GB, loaded: 1.1 * GB, state: S.PAUSED },
  { id: '5', name: 'archive.zip', relativePath: 'archive.zip', size: 40 * GB, loaded: 0, state: S.ERROR, quota: true, error: 'Not enough Disk space: this needs 40 GB and 12 GB is free.' },
  { id: '6', name: 'notes.md', relativePath: 'notes.md', size: 3000, loaded: 3000, state: S.DONE },
  { id: '7', name: 'site-backup.tar', relativePath: 'site-backup.tar', size: 5 * GB, loaded: 0, state: S.INTERRUPTED },
]

// The panel reads the shared upload store; the story fills it with fixtures.
const withItems = (Story) => {
  useUploadStore.setState({ items, conflictAll: null })
  return <div className="management"><Story /></div>
}

export const Mixed = { decorators: [withItems] }
