import { useRef, useEffect } from 'react'
import styles from './Tag.module.css'

export default function Tag({ children, bg, fg, variant = 'default' }) {
  const ref = useRef(null)
  const className = variant === 'square' ? styles.square : styles.tag

  useEffect(() => {
    if (ref.current) {
      if (bg) ref.current.style.setProperty('--tag-bg', bg)
      if (fg) ref.current.style.setProperty('--tag-fg', fg)
    }
  }, [bg, fg])

  return (
    <span ref={ref} className={className}>
      {children}
    </span>
  )
}
