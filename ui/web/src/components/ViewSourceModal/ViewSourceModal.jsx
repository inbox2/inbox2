import { useEffect, useRef } from 'react'
import Modal from '../Modal/Modal'
import Icon from '../Icon'
import IconButton from '../IconButton'
import Tooltip from '../Tooltip'
import styles from './ViewSourceModal.module.css'

export default function ViewSourceModal({ open, source, loading, onClose }) {
  const closeRef = useRef(null)

  useEffect(() => {
    if (open) closeRef.current?.focus()
  }, [open])

  const formatted = source ? JSON.stringify(source, null, 2) : ''

  return (
    <Modal open={open} onClose={onClose} showClose={false} className={styles.modal}>
      <div className={styles.header}>
        <Icon name="doc" size={16} />
        <h3 className={styles.title}>Message source</h3>
        <Tooltip content="Close (Esc)">
          <IconButton ref={closeRef} size="sm" icon="xmark" onClick={onClose} aria-label="Close" />
        </Tooltip>
      </div>
      <div className={styles.body}>
        {loading ? (
          <div className={styles.loading}>Loading source...</div>
        ) : (
          <pre className={styles.code}>{formatted}</pre>
        )}
      </div>
    </Modal>
  )
}
