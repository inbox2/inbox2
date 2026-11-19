import { useEffect, useRef, useState } from 'react'
import styles from '../setup.module.css'

// The first-launch intro: the inbox2 box opens, your channels fall in, the
// camera dives into the glow (rendered in Blender, public/intro/). Any key or
// click skips; the end fades through white into the Welcome step.
const FADE_MS = 450

export default function IntroStep({ onDone }) {
  const [fading, setFading] = useState(false)
  const done = useRef(false)

  const finish = () => {
    if (done.current) return
    done.current = true
    setFading(true)
    setTimeout(onDone, FADE_MS)
  }

  useEffect(() => {
    const onKey = () => finish()
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return (
    <div className={styles.intro} onClick={finish} role="presentation">
      <video className={styles.introVideo} autoPlay muted playsInline onEnded={finish} onError={finish} aria-label="inbox2: your channels fall into the box">
        <source src="/intro/intro.webm" type="video/webm" />
        <source src="/intro/intro.mp4" type="video/mp4" />
      </video>
      <div className={fading ? styles.introFadeOn : styles.introFade} />
      <button type="button" className={styles.introSkip} onClick={(e) => { e.stopPropagation(); finish() }}>
        Skip
      </button>
    </div>
  )
}
