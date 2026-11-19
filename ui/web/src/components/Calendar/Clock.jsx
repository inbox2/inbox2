import { useState, useEffect } from 'react'
import styles from './Clock.module.css'

// Live temporal header — seven-segment time + long date. Shared by the calendar
// sidebar and the unified inbox's calendar rail. Ticks every 60s (CSS blinks the
// colon) and pauses while the tab is hidden.

const is24h = (() => {
  const formatted = new Intl.DateTimeFormat(undefined, { hour: 'numeric' }).format(new Date(2000, 0, 1, 13))
  return formatted.includes('13')
})()

const localeHour = (date) => (is24h ? String(date.getHours()) : String(date.getHours() % 12 || 12))
const localePad = (n) => String(n).padStart(2, '0')
const localePeriod = (date) => (is24h ? null : (date.getHours() >= 12 ? 'PM' : 'AM'))

export default function Clock() {
  const [now, setNow] = useState(new Date())

  useEffect(() => {
    let timer = setInterval(() => setNow(new Date()), 60000)
    const handleVisibility = () => {
      clearInterval(timer)
      if (!document.hidden) {
        setNow(new Date())
        timer = setInterval(() => setNow(new Date()), 60000)
      }
    }
    document.addEventListener('visibilitychange', handleVisibility)
    return () => {
      clearInterval(timer)
      document.removeEventListener('visibilitychange', handleVisibility)
    }
  }, [])

  return (
    <div className={styles.temporalHeader}>
      <div className={styles.currentTime}>
        <span className={styles.clockDigits}>
          {localeHour(now)}
          <span className={styles.clockColon}>:</span>
          {localePad(now.getMinutes())}
        </span>
        {localePeriod(now) && <span className={styles.clockPeriod}>{localePeriod(now)}</span>}
      </div>
      <div className={styles.currentDate}>
        {now.toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' })}
      </div>
    </div>
  )
}
