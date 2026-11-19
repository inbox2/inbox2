import Button from '../../../components/Button/Button'
import { ErrorMessage } from '../../../components/FormField/FormField'
import useModelLanes from '../../../hooks/useModelLanes'
import JevKeyCard from '../../settings/JevKeyCard'
import { setAIConsent, downloadAllModels, initializeInference } from '../../../lib/ai'
import { aiLogo } from '../../../lib/ai/aiLogo'
import { deviceWord, getOS } from '../../../lib/tauri'
import styles from '../setup.module.css'


/**
 * Set up AI: the writing model (summaries, smart replies — Apple Intelligence,
 * a local Qwen/Gemma, or OpenAI; the same lanes as Settings › On-device AI) and
 * the decision model (Jev by TypeSafe, triage). Continue also opts in to the
 * small on-device sorting models, like the old consent step did.
 */
export default function AiStep({ onDone }) {
  const m = useModelLanes()

  const finish = () => {
    setAIConsent(true)
    downloadAllModels()
      .then(async (r) => { if (r?.success) await initializeInference() })
      .catch(() => {})
    onDone()
  }

  const native = m.rows.find(r => r.lane === 'native')
  const options = [
    // Apple Intelligence is a Mac feature: on Windows and Linux the card is not offered at all.
    native && getOS() === 'macos' && { key: 'native', logo: aiLogo('native'), name: 'Apple Intelligence', tag: 'On this Mac', desc: native.desc,
      enabled: native.enabled, selected: m.pref === 'native', pick: () => m.choose('native') },
    ...m.variantRows.map(v => ({ key: v.id, logo: aiLogo('free', v.id), name: v.name, tag: `On this ${deviceWord()} · free`, desc: v.desc,
      enabled: true, selected: m.pref === 'free' && m.freeModel === v.id, pick: () => m.chooseVariant(v) })),
    { key: 'openai', logo: aiLogo('openai'), name: 'OpenAI', tag: 'Cloud · your key',
      desc: m.hasKey ? 'Uses your API key. Mail text is sent to OpenAI.' : 'Add your API key below.',
      enabled: true, selected: m.pref === 'openai', pick: () => m.choose('openai') },
  ].filter(Boolean)

  return (
    <>
      <h1 className={styles.title}>Set up AI</h1>
      <p className={styles.subtitle}>Two jobs, two models: one writes for you, one decides what matters.</p>

      <div className={styles.aiColumns}>
        <section className={styles.aiSection} aria-labelledby="ai-writing">
          <div className={styles.aiSectionHead}>
            <h2 id="ai-writing" className={styles.aiSectionTitle}>Writing model</h2>
            <span className={styles.modeDesc}>Summaries and smart replies</span>
          </div>
          {m.ready ? (
            <div className={styles.aiGrid} role="radiogroup" aria-label="Writing model">
              {options.map(o => (
                <button
                  key={o.key}
                  type="button"
                  role="radio"
                  aria-checked={o.selected}
                  disabled={!o.enabled}
                  className={`${styles.aiCard} ${o.selected ? styles.aiCardSelected : ''}`}
                  onClick={o.pick}
                >
                  <span className={styles.aiLogoTile}><img src={o.logo} alt="" className={styles.aiLogo} /></span>
                  <span className={styles.aiCardText}>
                    <span className={styles.aiName}>{o.name}</span>
                    <span className={styles.aiTag}>{o.tag}</span>
                    <span className={styles.modeDesc}>{o.desc}</span>
                  </span>
                </button>
              ))}
            </div>
          ) : (
            <p className={styles.modeDesc}>Writing models are set up in the desktop app.</p>
          )}
          {m.ready && m.pref === 'openai' && !m.hasKey && (
            <div className={styles.aiKeyRow}>
              <input
                type="password"
                className={styles.aiKeyInput}
                placeholder="sk-…"
                aria-label="OpenAI API key"
                value={m.keyDraft}
                onChange={e => m.setKeyDraft(e.target.value)}
              />
              <Button onClick={m.saveKey} disabled={!m.keyDraft.trim()}>Save key</Button>
            </div>
          )}
          {m.keyStatus && <p className={styles.modeDesc}>{m.keyStatus}</p>}
          <ErrorMessage>{m.error}</ErrorMessage>
        </section>

        <section className={styles.aiSection} aria-labelledby="ai-decision">
          <div className={styles.aiSectionHead}>
            <h2 id="ai-decision" className={styles.aiSectionTitle}>Decision model</h2>
            <span className={styles.modeDesc}>Triage</span>
          </div>
          <JevKeyCard />
          <p className={styles.modeDesc}>
            Jev picks each thread&rsquo;s action, scores its priority 0&ndash;4 and files it in a Space.
            Without a key, triage uses built-in rules only. Sealed mail never goes to a cloud model.
          </p>
        </section>
      </div>

      <div className={styles.actions}>
        <Button variant="ghost" onClick={onDone}>Not now</Button>
        <Button onClick={finish}>Continue</Button>
      </div>
    </>
  )
}
