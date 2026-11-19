import { useEffect, useState } from 'react'
import Button from '../../../components/Button/Button'
import Icon from '../../../components/Icon'
import useTheme from '../../../hooks/useTheme'
import { getNluLane, getNluFreeModel } from '../../../lib/ai/lanePrefs'
import { getSecret } from '../../../lib/secretStore'
import { isTauri } from '../../../lib/tauri'
import { aiLogo } from '../../../lib/ai/aiLogo'
import styles from '../setup.module.css'

const LANE_NAME = { native: 'Apple Intelligence', openai: 'OpenAI' }

/** Ready: what was set up, each with its mark, then into the app. */
export default function CompleteStep({ mode, onFinish }) {
  const { theme } = useTheme()
  const [jev, setJev] = useState(false)
  useEffect(() => {
    if (!isTauri()) return undefined
    let active = true
    getSecret('typesafe_api_key').then(v => { if (active) setJev(!!v) }).catch(() => {})
    return () => { active = false }
  }, [])

  const lane = getNluLane()
  const freeModel = getNluFreeModel()
  const aiName = LANE_NAME[lane] || (lane === 'free' ? (freeModel.startsWith('gemma') ? 'Gemma 3 1B' : 'Qwen 2.5 1.5B') : null)

  return (
    <div className={styles.centered}>
      <img src="/channels/inbox2-box-open.png" alt="" width="96" height="99" className={styles.completeBox} />
      <h1 className={styles.title}>Your box is ready</h1>
      <p className={styles.subtitle}>
        {mode === 'mx' ? 'Your domain is connected and ready to receive mail.' : 'Mail keeps syncing while you look around.'}
      </p>

      <div className={styles.summary}>
        <div className={styles.summaryItem}>
          <span className={styles.modeDesc}>Look</span>
          <span className={styles.summaryValue}>
            <Icon name={theme.mode === 'light' ? 'sun.max.fill' : 'moon.fill'} size={16} />
            {theme.label}
          </span>
        </div>
        <div className={styles.summaryItem}>
          <span className={styles.modeDesc}>Writing</span>
          <span className={styles.summaryValue}>
            {aiName ? <><img src={aiLogo(lane, freeModel)} alt="" className={styles.summaryLogo} />{aiName}</> : 'Not set up'}
          </span>
        </div>
        <div className={styles.summaryItem}>
          <span className={styles.modeDesc}>Triage</span>
          <span className={styles.summaryValue}>
            <img src="/ai/jev.png" alt="" className={styles.summaryLogo} />
            {jev ? 'Jev' : 'Rules only'}
          </span>
        </div>
      </div>

      <Button onClick={onFinish}>Open my inbox</Button>
    </div>
  )
}
