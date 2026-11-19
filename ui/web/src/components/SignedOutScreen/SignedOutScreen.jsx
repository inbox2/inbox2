import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import Button from '../Button/Button'
import { MgmtButton } from '../management'
import styles from './SignedOutScreen.module.css'

// The button of the layer the screen sits over (defined once, so a re-render keeps focus).
function ScreenButton({ skin, primary, ...p }) {
  return skin === 'management'
    ? <MgmtButton variant={primary ? 'primary' : 'glass'} size={primary ? 'md' : 'sm'} {...p} />
    : <Button variant={primary ? undefined : 'secondary'} {...p} />
}

const MESSAGE = {
  elsewhere: 'You signed out in another tab or window.',
  expired: 'Your session ended.',
  revoked: 'An admin ended your access.',
}

/**
 * The one signed-out experience: shown over a tab that learns its session is
 * gone (another tab signed out, a 401, a revoke) instead of bouncing it to the
 * login page mid-task. The page stays mounted behind it, inert, so unsaved
 * editor text can still be copied. skin: 'aero' (mail, Disk, calendar) or
 * 'management' (console, onboarding). unsaved: [{ label, text }].
 */
export default function SignedOutScreen({ reason = 'elsewhere', unsaved = [], skin = 'aero', onSignIn }) {
  const box = useRef(null)
  const [copied, setCopied] = useState(null)

  // Blocking: everything behind is inert while this is up, and focus starts on the button.
  useEffect(() => {
    const root = document.getElementById('root')
    root?.setAttribute('inert', '')
    box.current?.querySelector('[data-primary]')?.focus()
    return () => root?.removeAttribute('inert')
  }, [])

  // Keep Tab inside the screen.
  const trap = (e) => {
    if (e.key !== 'Tab') return
    const items = [...box.current.querySelectorAll('button')]
    const i = items.indexOf(document.activeElement)
    const next = e.shiftKey ? (i <= 0 ? items.length - 1 : i - 1) : (i === items.length - 1 ? 0 : i + 1)
    e.preventDefault()
    items[next]?.focus()
  }

  const copy = async (entry, i) => {
    try { await navigator.clipboard.writeText(entry.text); setCopied(i) } catch { setCopied(-1) }
  }


  return createPortal(
    <div className={`${styles.backdrop} ${skin === 'management' ? `management ${styles.light}` : styles.dark}`}>
      <div ref={box} className={styles.card} role="alertdialog" aria-modal="true" aria-labelledby="signed-out-title" aria-describedby="signed-out-text" onKeyDown={trap}>
        <h1 id="signed-out-title" className={styles.title}>You are signed out</h1>
        <p id="signed-out-text" className={styles.text}>{MESSAGE[reason] || MESSAGE.elsewhere} Sign in again to carry on where you were.</p>
        {unsaved.length > 0 && (
          <div className={styles.unsaved}>
            <p className={styles.text}>This tab has open work whose last changes may not have been saved. Copy it now, or sign in again as the same account in another tab and this tab carries on with it.</p>
            <ul className={styles.list}>
              {unsaved.map((e, i) => (
                <li key={e.label} className={styles.item}>
                  <span>{e.label}</span>
                  <ScreenButton skin={skin} type="button" onClick={() => copy(e, i)}>{copied === i ? 'Copied' : 'Copy text'}</ScreenButton>
                </li>
              ))}
            </ul>
            {copied === -1 && <p className={styles.text} role="alert">This browser did not allow copying. Select the text in the page after signing in again.</p>}
          </div>
        )}
        <div className={styles.actions}>
          <ScreenButton skin={skin} primary data-primary type="button" onClick={onSignIn}>Sign in again</ScreenButton>
        </div>
      </div>
    </div>,
    document.body,
  )
}
