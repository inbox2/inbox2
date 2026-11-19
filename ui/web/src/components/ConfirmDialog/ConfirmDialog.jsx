import { useEffect, useRef } from 'react'
import Modal from '../Modal/Modal'
import Button from '../Button/Button'
import Icon from '../Icon'
import styles from './ConfirmDialog.module.css'

export default function ConfirmDialog({
  open,
  title = 'Are you sure?',
  message,
  confirmLabel = 'Confirm',
  cancelLabel = 'Cancel',
  variant = 'danger',
  onConfirm,
  onCancel,
}) {
  const confirmRef = useRef(null)

  useEffect(() => {
    if (!open) return
    const timer = setTimeout(() => confirmRef.current?.focus(), 50)
    return () => clearTimeout(timer)
  }, [open])

  return (
    <Modal open={open} onClose={onCancel} showClose={false} className={styles.dialog}>
      <div className={styles.header}>
        <Icon
          name={variant === 'danger' || variant === 'warning' ? 'exclamationmark.triangle' : 'checkmark.circle'}
          size={18}
        />
        <h3 className={styles.title}>{title}</h3>
      </div>

      {message && (
        <p className={styles.message}>{message}</p>
      )}

      <div className={styles.actions}>
        {/* cancelLabel={null}: an alert, one button. */}
        {cancelLabel && (
          <Button variant="secondary" className={styles.confirmBtn} onClick={onCancel}>
            {cancelLabel}
          </Button>
        )}
        <Button
          ref={confirmRef}
          variant={variant === 'danger' ? 'danger' : undefined}
          className={styles.confirmBtn}
          onClick={onConfirm}
        >
          {confirmLabel}
        </Button>
      </div>
    </Modal>
  )
}
