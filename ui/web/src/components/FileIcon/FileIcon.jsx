import { useState, useEffect } from 'react'
import log from '../../lib/log'
import styles from './FileIcon.module.css'

// Cache native file-type icons across instances (ext → data URI).
const iconCache = new Map()

/**
 * Native OS file-type icon for a filename's extension, resolved via the desktop
 * `get_file_type_icon` command. Renders nothing off-desktop (web/Storybook) or
 * until the icon resolves. Shared by the message-detail attachment chips and the
 * composer's attachment tokens.
 */
export default function FileIcon({ filename, size = 20 }) {
  const ext = (filename || '').split('.').pop().toLowerCase()
  const [src, setSrc] = useState(iconCache.get(ext) || null)

  useEffect(() => {
    if (src || !ext) return
    import('@tauri-apps/api/core').then(({ invoke }) =>
      invoke('get_file_type_icon', { ext, size: size * 2 })
    ).then(dataUri => {
      iconCache.set(ext, dataUri)
      setSrc(dataUri)
    }).catch((e) => log.warn('FileIcon', `failed for ${ext}: ${e}`))
  }, [ext, size, src])

  if (!src) return null
  return <img src={src} width={size} height={size} alt={ext} className={styles.fileIcon} />
}
