import '../../styles/management.css'
import FileTypeIcon from './FileTypeIcon'
import ActionIcon from './ActionIcon'
import { EMBLEMS, ACTION_PATHS } from './glyphs'
import { FILE_ICONS, typeForIcon } from '../../lib/disk/fileTypes'
import styles from './FileTypeIcon.stories.module.css'

export default {
  title: 'Disk/FileTypeIcon',
  component: FileTypeIcon,
}

const Cell = ({ label, children }) => (
  <figure className={styles.cell}>{children}<figcaption>{label}</figcaption></figure>
)

export const AllTypes = {
  render: () => (
    <div className={`management ${styles.grid}`}>
      <Cell label="Folder"><FileTypeIcon kind="folder" size={40} /></Cell>
      <Cell label="Shared folder"><FileTypeIcon kind="folder" shared size={40} /></Cell>
      <Cell label="Sealed folder"><FileTypeIcon kind="folder" sealed size={40} /></Cell>
      <Cell label="Page"><FileTypeIcon kind="page" size={40} /></Cell>
      {FILE_ICONS.map((icon) => (
        <Cell key={icon} label={typeForIcon(icon).label}><FileTypeIcon type={icon} size={40} /></Cell>
      ))}
    </div>
  ),
}

export const ByFileName = {
  args: { kind: 'file', name: 'Budget 2026.xlsx', size: 56 },
  render: (args) => <div className="management"><FileTypeIcon {...args} /></div>,
}

export const Shares = {
  render: () => (
    <div className={`management ${styles.grid}`}>
      {Object.keys(EMBLEMS).filter((e) => e !== 'shared' && e !== 'sealed').map((e) => (
        <Cell key={e} label={e}><FileTypeIcon kind="share" emblem={e} size={64} /></Cell>
      ))}
      <Cell label="marketing, teal"><FileTypeIcon kind="share" emblem="marketing" color="teal" size={64} /></Cell>
    </div>
  ),
}

export const Drives = {
  render: () => (
    <div className={`management ${styles.grid}`}>
      <Cell label="C:\"><FileTypeIcon kind="drive" drive="C" size={24} /></Cell>
      <Cell label="D:\"><FileTypeIcon kind="drive" drive="D" size={24} /></Cell>
    </div>
  ),
}

export const Actions = {
  render: () => (
    <div className={`management ${styles.grid}`}>
      {Object.keys(ACTION_PATHS).map((n) => <Cell key={n} label={n}><ActionIcon name={n} /></Cell>)}
    </div>
  ),
}
