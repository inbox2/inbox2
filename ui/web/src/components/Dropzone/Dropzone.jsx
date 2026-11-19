import { forwardRef, useImperativeHandle, useRef, useState } from 'react'
import { filesFromDataTransfer, filesFromInput } from '../../lib/disk/dropFiles'
import styles from './Dropzone.module.css'

const hasFiles = (e) => [...(e.dataTransfer?.types || [])].includes('Files')

/**
 * Drop target with a visible overlay while files are dragged over it (spec F2:
 * drop anywhere on the page, folders included). Reports files, uploads nothing.
 * The keyboard path is `choose`: choose() / choose('folder') opens the file or
 * folder picker. It reaches children (when a function, given { choose }) and
 * the ref ({ choose }), for buttons and menus outside the drop area.
 *
 *   onFiles   ([{ file, relativePath }]) => void; folders arrive flattened, relativePath keeps the tree
 *   label     overlay text, e.g. "Drop to upload to D:\Marketing"
 *   children  node, or ({ choose }) => node
 */
const Dropzone = forwardRef(function Dropzone({ onFiles, label = 'Drop files to upload', children }, ref) {
  const [over, setOver] = useState(false)
  const depth = useRef(0)
  // Inputs held in state, not refs, so `choose` can be handed to children during render.
  const [filesInput, setFilesInput] = useState(null)
  const [folderInput, setFolderInput] = useState(null)

  const onDragEnter = (e) => {
    if (!hasFiles(e)) return
    e.preventDefault()
    depth.current += 1
    setOver(true)
  }
  const onDragOver = (e) => {
    if (!hasFiles(e)) return
    e.preventDefault()
    e.dataTransfer.dropEffect = 'copy'
  }
  const onDragLeave = (e) => {
    if (!hasFiles(e)) return
    depth.current = Math.max(0, depth.current - 1)
    if (!depth.current) setOver(false)
  }
  const onDrop = async (e) => {
    if (!hasFiles(e)) return
    e.preventDefault()
    depth.current = 0
    setOver(false)
    const list = await filesFromDataTransfer(e.dataTransfer)
    if (list.length) onFiles(list)
  }
  const onPick = (e) => {
    const list = filesFromInput(e.target.files)
    e.target.value = ''
    if (list.length) onFiles(list)
  }
  const choose = (what) => (what === 'folder' ? folderInput : filesInput)?.click()
  useImperativeHandle(ref, () => ({ choose }))

  return (
    <div className={styles.zone} role="presentation" onDragEnter={onDragEnter} onDragOver={onDragOver} onDragLeave={onDragLeave} onDrop={onDrop}>
      {typeof children === 'function' ? children({ choose }) : children}
      <input ref={setFilesInput} type="file" multiple hidden tabIndex={-1} onChange={onPick} />
      <input ref={setFolderInput} type="file" webkitdirectory="" hidden tabIndex={-1} onChange={onPick} />
      {over && <div className={styles.overlay} aria-hidden="true"><span className={styles.label}>{label}</span></div>}
    </div>
  )
})

export default Dropzone
