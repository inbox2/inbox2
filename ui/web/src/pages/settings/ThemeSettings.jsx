import { useCallback, useEffect, useRef, useState } from 'react';
import useTheme from '../../hooks/useTheme';
import { EDITABLE_TOKEN_GROUPS, BACKGROUND_MODE, TEXT_SCALES, getTheme } from '../../lib/themes';
import { readThemeTokens } from '../../lib/readThemeTokens';
import Icon from '../../components/Icon';
import IconButton from '../../components/IconButton/IconButton';
import Switch from '../../components/Switch/Switch';
import ThemeModeSwitch from '../../components/ThemeModeSwitch/ThemeModeSwitch';
import { MgmtSelect } from '../../components/management';
import useRainbowTabs, { setRainbowTabsEnabled } from '../../lib/rainbowTabsPref';
import { isTauri } from '../../lib/tauri';
import { APP_ICONS, useAppIcon, setAppIcon, previewSrc } from '../../lib/appIcon';
import settings from './settings.module.css';
import styles from './ThemeSettings.module.css';

export default function ThemeSettings() {
  const { theme, themeId, themes, setTheme } = useTheme();
  // Switching mode lands on the plain theme of that mode, as in the setup wizard.
  const pickMode = (m) => {
    if (m !== theme.mode) setTheme(themes.find((t) => t.id === m)?.id || themes.find((t) => t.mode === m).id);
  };

  return (
    <>
      <h1 className={settings.settingsTitle}>Theme</h1>
      <p className={styles.intro}>
        Choose the look of your workspace. Fine-tune any colour under Advanced.
      </p>

      <div className={isTauri() ? styles.layout : undefined}>
        <div className={styles.themeCol}>
          <div className={styles.modeRow}>
            <ThemeModeSwitch mode={theme.mode} onChange={pickMode} />
          </div>
          <div role="radiogroup" aria-label="Theme" className={styles.cardGrid}>
            {themes.filter((t) => t.mode === theme.mode).map((t) => (
              <ThemeCard key={t.id} theme={t} selected={t.id === themeId} onSelect={() => setTheme(t.id)} />
            ))}
          </div>
        </div>

        <AppIconPicker />
      </div>

      <ThemeCustomizer />
    </>
  );
}

/**
 * Desktop-only app-icon picker. A running process can't rewrite its own bundle
 * icon, so this repaints the Dock/taskbar now and main.jsx re-applies the choice
 * on the next launch.
 */
function AppIconPicker() {
  const icon = useAppIcon();
  if (!isTauri()) return null;

  const choose = (id) => setAppIcon(id);

  return (
    <div className={styles.group}>
      <div className={styles.groupLabel}>App icon</div>
      <div role="radiogroup" aria-label="App icon" className={styles.iconGrid}>
        {APP_ICONS.map((opt) => (
          <button
            key={opt.id}
            type="button"
            role="radio"
            aria-checked={opt.id === icon}
            onClick={() => choose(opt.id)}
            className={`${styles.iconCard} ${opt.id === icon ? styles.iconCardSelected : ''}`}
          >
            <img src={previewSrc(opt.id)} alt="" className={styles.iconSwatch} />
            <span>
              <span className={styles.iconLabel}>{opt.label}</span>
              <span className={styles.iconBlurb}>{opt.blurb}</span>
            </span>
          </button>
        ))}
      </div>
      <p className={styles.iconNote}>
        Changes the Dock and window icon right away. Finder and Launchpad keep the original icon.
      </p>
    </div>
  );
}

function ThemeCard({ theme, selected, onSelect }) {
  // Paint preview colours via CSS custom properties (inline styles are banned).
  const setVars = useCallback((el) => {
    if (!el) return;
    el.style.setProperty('--c-bg-color', theme.swatch.bg);
    el.style.setProperty('--c-bg-image', theme.background ? `url("${theme.background}")` : 'none');
    el.style.setProperty('--c-fg', theme.swatch.fg);
    el.style.setProperty('--c-accent', theme.swatch.accent);
  }, [theme]);

  return (
    <button
      type="button"
      role="radio"
      aria-checked={selected}
      className={`${styles.card} ${selected ? styles.cardSelected : ''}`}
      onClick={onSelect}
    >
      <span ref={setVars} className={styles.preview}>
        <span className={styles.previewSurface}>
          <span className={styles.previewText}>Aa</span>
          <span className={styles.previewButtons}>
            <span className={styles.previewBtnPrimary}>Send</span>
            <span className={styles.previewBtnSecondary} />
          </span>
        </span>
      </span>
      <span className={styles.cardFooter}>
        <span className={styles.cardText}>
          <span className={styles.cardLabel}>{theme.label}</span>
          {theme.description && <span className={styles.cardDesc}>{theme.description}</span>}
        </span>
        {selected && <Icon name="checkmark.circle.fill" className={styles.cardCheck} />}
      </span>
    </button>
  );
}

// ── Advanced per-theme customizer ───────────────────────────────────────────────
// An expandable section under the picker: override any curated token on the active
// theme. Edits apply live (via useTheme.setOverride) and persist per theme.
function ThemeCustomizer() {
  const {
    theme, overrides, setOverride, resetOverrides, exportCurrent, importShared,
    background, setBackgroundMode, setCustomBackground, clearCustomBackground,
    textScale, setTextScale,
  } = useTheme();
  const count = Object.keys(overrides).length;
  const { enabled: rainbowTabs } = useRainbowTabs();
  // Whether this theme ships a backdrop image (dark themes) vs. defaulting to the
  // dot grid (light). Read from the base theme, not the resolved one, since the
  // resolved background reflects the current mode. Drives the Default label and
  // whether the redundant "None" option is offered.
  const shipsBackdrop = !!getTheme(theme.id).background;
  const fileRef = useRef(null);
  const bgFileRef = useRef(null);
  const [status, setStatus] = useState(null); // { kind: 'ok' | 'err', text }

  const handleExport = useCallback(() => {
    const data = exportCurrent();
    const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `inbox2-theme-${data.baseThemeId}.json`;
    a.click();
    URL.revokeObjectURL(url);
    setStatus({ kind: 'ok', text: 'Exported theme file.' });
  }, [exportCurrent]);

  const handleImportFile = useCallback(async (e) => {
    const file = e.target.files?.[0];
    e.target.value = ''; // let the same file be re-imported
    if (!file) return;
    try {
      const data = JSON.parse(await file.text());
      importShared(data);
      const n = Object.keys(data.overrides || {}).length;
      setStatus({ kind: 'ok', text: `Imported “${data.baseLabel || data.baseThemeId}” (${n} override${n === 1 ? '' : 's'}).` });
    } catch (err) {
      setStatus({ kind: 'err', text: err.message || 'Invalid theme file.' });
    }
  }, [importShared]);

  const handleBgSelect = useCallback((e) => {
    const mode = e.target.value;
    if (mode !== BACKGROUND_MODE.CUSTOM) { setBackgroundMode(mode); return; }
    setBackgroundMode(BACKGROUND_MODE.CUSTOM);
    // No image yet → open the browser straight away. Cancelling reverts to
    // Default via the input's `cancel` event (wired below).
    if (!background.image) bgFileRef.current?.click();
  }, [setBackgroundMode, background.image]);

  // Dialog dismissed with no file chosen: if there's no stored image, flip back
  // to Default so the dropdown doesn't sit on "Custom" with nothing applied.
  useEffect(() => {
    const el = bgFileRef.current;
    if (!el) return undefined;
    const onCancel = () => { if (!background.image) setBackgroundMode(BACKGROUND_MODE.DEFAULT); };
    el.addEventListener('cancel', onCancel);
    return () => el.removeEventListener('cancel', onCancel);
  }, [background.image, setBackgroundMode]);

  const handleBgFile = useCallback(async (e) => {
    const file = e.target.files?.[0];
    e.target.value = '';
    if (!file) return;
    try {
      const dataUrl = await fileToScaledDataURL(file);
      setCustomBackground(dataUrl);
      setStatus({ kind: 'ok', text: 'Custom background applied.' });
    } catch (err) {
      setStatus({
        kind: 'err',
        text: err?.name === 'QuotaExceededError'
          ? 'That image is too large to save. Try a smaller one.'
          : (err.message || "Couldn't load that image."),
      });
    }
  }, [setCustomBackground]);

  return (
    <details className={styles.advanced}>
      <summary className={styles.advancedSummary}>
        <Icon name="wrench.fill" className={styles.advancedIcon} />
        <span className={styles.advancedTitle}>Advanced: customize “{theme.label}”</span>
        {count > 0 && <span className={styles.advancedCount}>{count}</span>}
        <Icon name="chevron.right" className={styles.advancedChevron} />
      </summary>

      <div className={styles.advancedBody}>
        <p className={styles.advancedHint}>
          Change any colour in this theme. This browser saves your changes for each theme.
        </p>

        <div className={styles.tokenGroup}>
          <div className={styles.tokenGroupLabel}>Background</div>
          <div className={styles.bgControl}>
            <MgmtSelect
              bare
              className={styles.bgSelect}
              value={background.mode}
              onChange={handleBgSelect}
              aria-label="Background source"
            >
              <option value={BACKGROUND_MODE.DEFAULT}>
                {shipsBackdrop ? `Default (${theme.label} backdrop)` : 'Default (dot grid)'}
              </option>
              {/* "None" only differs from Default when the theme ships a backdrop
                  image (dark themes); for themes that default to the grid it's
                  redundant, so omit it. */}
              {shipsBackdrop && <option value={BACKGROUND_MODE.NONE}>None (dot grid)</option>}
              <option value={BACKGROUND_MODE.CUSTOM}>Custom image…</option>
            </MgmtSelect>
            {background.mode === BACKGROUND_MODE.CUSTOM && (
              <>
                <button
                  type="button"
                  className={styles.shareBtn}
                  onClick={() => bgFileRef.current?.click()}
                >
                  <Icon name="photo" className={styles.shareIcon} />
                  {background.image ? 'Change…' : 'Browse…'}
                </button>
                {background.image && (
                  <IconButton
                    icon="xmark"
                    size="sm"
                    title="Remove custom background"
                    aria-label="Remove custom background"
                    onClick={clearCustomBackground}
                  />
                )}
              </>
            )}
            <input
              ref={bgFileRef}
              type="file"
              accept="image/*"
              hidden
              onChange={handleBgFile}
            />
          </div>
          {background.mode === BACKGROUND_MODE.CUSTOM && background.image && (
            <img className={styles.bgThumb} src={background.image} alt="" />
          )}
        </div>

        <div className={styles.tokenGroup}>
          <div className={styles.tokenGroupLabel}>Text size</div>
          {/* Native range input — 4 stops, themed with accent-color. */}
          <input
            type="range"
            className={styles.scaleSlider}
            min={0}
            max={TEXT_SCALES.length - 1}
            step={1}
            value={Math.max(0, TEXT_SCALES.findIndex((s) => s.value === textScale))}
            onChange={(e) => setTextScale(TEXT_SCALES[Number(e.target.value)].value)}
            aria-label="Text size"
            aria-valuetext={TEXT_SCALES.find((s) => s.value === textScale)?.label}
          />
          <div className={styles.scaleTicks} aria-hidden="true">
            {TEXT_SCALES.map((s) => (
              <span
                key={s.value}
                className={`${styles.scaleTick}${textScale === s.value ? ` ${styles.scaleTickActive}` : ''}`}
              >
                {s.label}
              </span>
            ))}
          </div>
        </div>

        <div className={styles.tokenGroup}>
          <div className={styles.tokenGroupLabel}>Tabs</div>
          <Switch
            id="rainbow-tabs"
            label="Use rainbow tabs"
            description="Tint each tab with a colour from the Catppuccin palette, like Obsidian's rainbow folders."
            checked={rainbowTabs}
            onChange={setRainbowTabsEnabled}
          />
        </div>

        {EDITABLE_TOKEN_GROUPS.map((group) => (
          <div key={group.label} className={styles.tokenGroup}>
            <div className={styles.tokenGroupLabel}>{group.label}</div>
            <div className={styles.tokenList}>
              {group.tokens.map((tk) => (
                <TokenRow
                  // Remount when the override changes externally (e.g. reset all)
                  // so the text field re-seeds from the new value.
                  key={`${theme.id}:${tk.key}:${overrides[tk.key] ?? ''}`}
                  token={tk}
                  overrideValue={overrides[tk.key]}
                  onChange={setOverride}
                />
              ))}
            </div>
          </div>
        ))}

        <div className={styles.shareRow}>
          <button type="button" className={styles.shareBtn} onClick={handleExport}>
            <Icon name="arrow.up.right" className={styles.shareIcon} />
            Export
          </button>
          <button type="button" className={styles.shareBtn} onClick={() => fileRef.current?.click()}>
            <Icon name="tray.and.arrow.down" className={styles.shareIcon} />
            Import
          </button>
          <input
            ref={fileRef}
            type="file"
            accept="application/json,.json"
            hidden
            onChange={handleImportFile}
          />
        </div>

        {status && (
          <p className={styles.shareMsg} data-kind={status.kind}>{status.text}</p>
        )}

        {count > 0 && (
          <button type="button" className={styles.resetAll} onClick={resetOverrides}>
            <Icon name="arrow.uturn.backward" className={styles.resetAllIcon} />
            Reset all to {theme.label} defaults
          </button>
        )}
      </div>
    </details>
  );
}

// Load an image file, downscale to a sane max width, and return a compact data URL
// (kept small so it fits in localStorage alongside the rest of the theme state).
async function fileToScaledDataURL(file, maxW = 2880, quality = 0.85) {
  if (!file.type?.startsWith('image/')) throw new Error('Choose an image file.');
  const bitmap = await createImageBitmap(file);
  const scale = Math.min(1, maxW / bitmap.width);
  const w = Math.max(1, Math.round(bitmap.width * scale));
  const h = Math.max(1, Math.round(bitmap.height * scale));
  const canvas = document.createElement('canvas');
  canvas.width = w;
  canvas.height = h;
  canvas.getContext('2d').drawImage(bitmap, 0, 0, w, h);
  bitmap.close?.();
  return canvas.toDataURL('image/webp', quality);
}

// The currently-applied value of a CSS custom property on <html>.
function resolveToken(key) {
  return readThemeTokens([key])[key];
}

// Best-effort #rrggbb for the native colour input (alpha dropped). The text field
// remains the source of truth for values a picker can't express (rgba, gradients).
function toHex(value) {
  if (!value) return '#000000';
  const ctx = (toHex._ctx ||= document.createElement('canvas').getContext('2d'));
  ctx.fillStyle = '#000000';
  ctx.fillStyle = value; // invalid values are ignored → stays #000000
  const norm = ctx.fillStyle; // '#rrggbb' (opaque) or 'rgba(r, g, b, a)'
  const m = norm.match(/^rgba?\((\d+),\s*(\d+),\s*(\d+)/i);
  if (m) return `#${[m[1], m[2], m[3]].map((n) => Number(n).toString(16).padStart(2, '0')).join('')}`;
  return norm.startsWith('#') ? norm : '#000000';
}

function TokenRow({ token, overrideValue, onChange }) {
  const computed = resolveToken(token.key);
  const [text, setText] = useState(overrideValue ?? '');
  const overridden = overrideValue != null;

  // Live swatch — background follows the token var itself, so it reflects any
  // override automatically. Set via ref since inline styles are banned.
  const swatchRef = useCallback((el) => {
    if (el) el.style.setProperty('--swatch', `var(${token.key})`);
  }, [token.key]);

  const commit = () => onChange(token.key, text.trim());

  return (
    <div className={`${styles.tokenRow} ${overridden ? styles.tokenRowOn : ''}`}>
      <span ref={swatchRef} className={styles.swatch} />
      <span className={styles.tokenLabel}>{token.label}</span>
      {token.picker !== false && (
        <input
          type="color"
          className={styles.colorInput}
          value={toHex(overrideValue || computed)}
          aria-label={`${token.label} colour`}
          onChange={(e) => onChange(token.key, e.target.value)}
        />
      )}
      <input
        type="text"
        className={styles.textInput}
        value={text}
        placeholder={computed}
        spellCheck={false}
        aria-label={`${token.label} value`}
        onChange={(e) => setText(e.target.value)}
        onBlur={commit}
        onKeyDown={(e) => {
          if (e.key === 'Enter') { commit(); e.currentTarget.blur(); }
          if (e.key === 'Escape') { setText(overrideValue ?? ''); e.currentTarget.blur(); }
        }}
      />
      <IconButton
        icon="arrow.uturn.backward"
        size="sm"
        title="Reset to theme default"
        aria-label={`Reset ${token.label}`}
        disabled={!overridden}
        onClick={() => onChange(token.key, '')}
      />
    </div>
  );
}
