import { useState } from 'react'
import '../../styles/management.css'
import Dropzone from './Dropzone'
import { MgmtButton } from '../management'
import styles from './Dropzone.stories.module.css'

export default {
  title: 'Disk/Dropzone',
  component: Dropzone,
}

function Demo() {
  const [got, setGot] = useState([])
  return (
    <div className="management">
      <Dropzone onFiles={setGot} label="Drop to upload to D:\Marketing">
        {({ choose }) => (
          <div className={styles.area}>
            <p>Drop files or a folder here.</p>
            <MgmtButton size="sm" onClick={() => choose()}>Choose files</MgmtButton>{' '}
            <MgmtButton size="sm" variant="glass" onClick={() => choose('folder')}>Choose folder</MgmtButton>
            <ul>{got.map((g) => <li key={g.relativePath}>{g.relativePath} ({g.file.size} bytes)</li>)}</ul>
          </div>
        )}
      </Dropzone>
    </div>
  )
}

export const Default = { render: () => <Demo /> }
