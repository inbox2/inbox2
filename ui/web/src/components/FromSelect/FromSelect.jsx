import { useState, useRef, useCallback, useMemo } from 'react'
import { createPortal } from 'react-dom'
import useDismiss from '../../hooks/useDismiss'
import Icon from '../Icon'
import { ProviderIcon } from '../AccountSwitcher/AccountSwitcher'
import styles from './FromSelect.module.css'

/**
 * Account picker: a dropdown of identities, each shown as provider icon + line
 * of text. The compose header's "From" (org domains + connected accounts, keyed
 * by email) and the calendar editor's target calendar (several per account, so
 * keyed by `id`) are the same control — a list of things belonging to a channel,
 * picked by one that is visibly that channel's.
 *
 * An identity is `{key, email, label?, id?, providerType, iconUrl?, avatarUrl?}`.
 * `id` is what `value`/`onChange` speak when present, `email` otherwise; `label`
 * renders above the email unless it repeats it. Falls back to displaying
 * whatever `value` is set when it matches no identity (e.g. a preserved reply
 * From).
 */
export default function FromSelect({ value, identities, onChange }) {
  const [open, setOpen] = useState(false)
  const triggerRef = useRef(null)
  const menuRef = useRef(null)

  const idOf = (identity) => identity.id ?? identity.email
  const selected = useMemo(
    () => identities.find((i) => String(idOf(i)).toLowerCase() === String(value || '').toLowerCase()) || null,
    [identities, value],
  )

  const position = useCallback((node) => {
    if (!node || !triggerRef.current) return
    const r = triggerRef.current.getBoundingClientRect()
    node.style.setProperty('--from-menu-top', `${r.bottom + 4}px`)
    node.style.setProperty('--from-menu-left', `${r.left}px`)
    node.style.setProperty('--from-menu-width', `${r.width}px`)
  }, [])

  const menuCallbackRef = useCallback((node) => {
    menuRef.current = node
    position(node)
  }, [position])

  // Outside-click / Escape close. The trigger is outside the portaled menu, so
  // ignore pointer-downs on it (its own onClick toggles); Escape returns focus.
  const dismiss = useCallback((e) => {
    if (e.type === 'mousedown' && triggerRef.current?.contains(e.target)) return
    setOpen(false)
    if (e.key === 'Escape') triggerRef.current?.focus()
  }, [])
  useDismiss(menuRef, dismiss, open)

  const pick = useCallback((id) => {
    onChange(id)
    setOpen(false)
    triggerRef.current?.focus()
  }, [onChange])

  return (
    <>
      <button
        ref={triggerRef}
        type="button"
        className={styles.trigger}
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="listbox"
        aria-expanded={open}
      >
        <span className={styles.triggerIcon}>
          {selected
            ? <ProviderIcon type={selected.providerType} iconUrl={selected.iconUrl} avatarUrl={selected.avatarUrl} size={16} />
            : <Icon name="person.crop.circle" size={16} />}
        </span>
        <span className={`${styles.triggerEmail} ${!selected ? styles.triggerPlaceholder : ''}`}>
          {selected?.email || value || 'Choose an address'}
        </span>
        <Icon name="chevron.up.chevron.down" size={10} className={styles.triggerChevron} />
      </button>

      {open && createPortal(
        <div ref={menuCallbackRef} className={styles.menu} role="listbox" aria-label="Send from">
          {identities.map((identity) => {
            const active = String(idOf(identity)).toLowerCase() === String(value || '').toLowerCase()
            return (
              <button
                key={identity.key}
                type="button"
                role="option"
                aria-selected={active}
                className={`${styles.option} ${active ? styles.optionActive : ''}`}
                onClick={() => pick(idOf(identity))}
              >
                <span className={styles.optionIcon}>
                  <ProviderIcon type={identity.providerType} iconUrl={identity.iconUrl} avatarUrl={identity.avatarUrl} size={18} />
                </span>
                <span className={styles.optionText}>
                  {identity.label && identity.label !== identity.email && (
                    <span className={styles.optionLabel}>{identity.label}</span>
                  )}
                  <span className={styles.optionEmail}>{identity.email}</span>
                </span>
                {active && <Icon name="checkmark" size={11} className={styles.optionCheck} />}
              </button>
            )
          })}
        </div>,
        document.body,
      )}
    </>
  )
}
