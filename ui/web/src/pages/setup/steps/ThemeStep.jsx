import Button from '../../../components/Button/Button'
import ThemeModeSwitch from '../../../components/ThemeModeSwitch/ThemeModeSwitch'
import useTheme from '../../../hooks/useTheme'
import { TEXT_SCALES } from '../../../lib/themes'
import { THEME_PICKED_KEY } from '../useSetupDarkUntilPicked'
import styles from '../setup.module.css'

// Each theme's swatch colour is data, so it rides in as a CSS custom property.
const swatch = (color) => (el) => el?.style.setProperty('--swatch', color)

/** Pick your look: dark or light first, then a theme of that mode, plus text size. */
export default function ThemeStep({ onContinue }) {
  const { theme, themes, setTheme: applyTheme, textScale, setTextScale } = useTheme()
  const setTheme = (id) => {
    localStorage.setItem(THEME_PICKED_KEY, '1')
    applyTheme(id)
  }
  const mode = theme.mode

  // Switching mode lands on the plain theme of that mode (Dark / Light).
  const pickMode = (m) => {
    if (m !== mode) setTheme(themes.find(t => t.id === m)?.id || themes.find(t => t.mode === m).id)
  }

  return (
    <>
      <h1 className={styles.title}>Pick your look</h1>
      <p className={styles.subtitle}>Dark or light first, then a theme. Change it any time in Settings › Appearance.</p>

      <div className={styles.modeSwitch}>
        <ThemeModeSwitch mode={mode} onChange={pickMode} />
      </div>

      <div className={styles.themeGrid} role="radiogroup" aria-label="Theme">
        {themes.filter(t => t.mode === mode).map(t => (
          <button
            key={t.id}
            type="button"
            role="radio"
            aria-checked={theme.id === t.id}
            className={`${styles.themeCard} ${theme.id === t.id ? styles.themeCardSelected : ''}`}
            onClick={() => setTheme(t.id)}
          >
            <span className={styles.themeThumb} ref={swatch(t.swatch.bg)}>
              {t.background && <img src={t.background} alt="" className={styles.themeThumbImg} />}
              <span className={styles.themeDots}>
                <span className={styles.themeDot} ref={swatch(t.swatch.fg)} />
                <span className={styles.themeDot} ref={swatch(t.swatch.accent)} />
              </span>
            </span>
            <span className={styles.themeName}>{t.label}</span>
            <span className={styles.themeDesc}>{t.description}</span>
          </button>
        ))}
      </div>

      <div className={styles.textSizeRow}>
        <span className={styles.modeDesc}>Text size</span>
        <div className={styles.textSizes} role="radiogroup" aria-label="Text size">
          {TEXT_SCALES.map(s => (
            <button
              key={s.value}
              type="button"
              role="radio"
              aria-checked={textScale === s.value}
              className={`${styles.textSize} ${textScale === s.value ? styles.textSizeSelected : ''}`}
              onClick={() => setTextScale(s.value)}
            >
              {s.label}
            </button>
          ))}
        </div>
      </div>

      <div className={styles.actions}>
        <Button onClick={onContinue}>Continue</Button>
      </div>
    </>
  )
}
