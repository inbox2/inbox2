import { useState, useEffect, useRef, useCallback } from 'react';
import Icon from '../../components/Icon';
import Spinner from '../../components/Spinner';
import EspIcon from '../../components/EspIcon/EspIcon';
import { MgmtButton, MgmtSelect } from '../../components/management';
import useDismiss from '../../hooks/useDismiss';
import api from '../../lib/api';
import log from '../../lib/log';
import admin from './adminShared.module.css';
import styles from './DomainSettingsPage.module.css';
import deliv from './Deliverability.module.css';

/* Deliverability tab — pick how this domain's outbound mail is sent: inbox2's
 * built-in deliverability, or the customer's own ESP (SES / SendGrid / Mailgun /
 * Postmark / Messy / custom SMTP). The provider catalog + field schema come from
 * the API (DeliveryProviders); secrets are write-only (shown as "saved"). */

const BUILTIN = 'builtin';
const CUSTOM = 'custom';

// Default field values for a freshly-picked provider (so selects aren't blank).
function defaultConfig(provider) {
  const cfg = {};
  (provider?.fields || []).forEach((f) => { if (f.default != null) cfg[f.key] = f.default; });
  return cfg;
}

export default function DeliverabilityPanel({ domain }) {
  const [loading, setLoading] = useState(true);
  const [providers, setProviders] = useState([]);
  const [mode, setMode] = useState(BUILTIN);
  const [kind, setKind] = useState('ses');
  const [config, setConfig] = useState({});
  // Presence flags for saved secrets ({ api_key_set: true }) → "saved" hints.
  const [savedFlags, setSavedFlags] = useState({});
  const [busy, setBusy] = useState(null); // 'save' | 'test' | null
  const [error, setError] = useState(null);
  const [savedOk, setSavedOk] = useState(false);
  const [testResult, setTestResult] = useState(null);

  const applyState = useCallback((d) => {
    setMode(d.mode || BUILTIN);
    if (d.mode === CUSTOM && d.kind) setKind(d.kind);
    const cfg = d.config || {};
    const flags = {};
    const values = {};
    Object.entries(cfg).forEach(([k, v]) => {
      if (k.endsWith('_set')) flags[k] = v; else values[k] = v;
    });
    setSavedFlags(flags);
    setConfig(values);
  }, []);

  useEffect(() => {
    let cancelled = false;
    api.getDeliverability(domain.key)
      .then((res) => { if (!cancelled && res.deliverability) { setProviders(res.deliverability.providers || []); applyState(res.deliverability); } })
      .catch((e) => log.warn('Deliverability', `load failed: ${e?.message || e}`))
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [domain.key, applyState]);

  const selected = providers.find((p) => p.kind === kind) || null;

  const pickProvider = (k) => {
    setKind(k);
    setTestResult(null);
    setSavedOk(false);
    // Reset fields to the provider's defaults; saved secrets stay flagged only
    // for the currently-saved provider.
    const provider = providers.find((p) => p.kind === k);
    setConfig(defaultConfig(provider));
    setSavedFlags({});
  };

  const setField = (key, value) => {
    setConfig((c) => ({ ...c, [key]: value }));
    setSavedOk(false);
    setTestResult(null);
  };

  const save = async () => {
    setBusy('save'); setError(null); setSavedOk(false); setTestResult(null);
    try {
      const payload = mode === BUILTIN ? { mode: BUILTIN } : { mode: CUSTOM, kind, config };
      const res = await api.updateDeliverability(domain.key, payload);
      if (res.deliverability) applyState(res.deliverability);
      setSavedOk(true);
    } catch (e) {
      log.warn('Deliverability', `save failed: ${e?.message || e}`);
      setError(e?.message || 'Couldn’t save deliverability settings.');
    } finally { setBusy(null); }
  };

  const test = async () => {
    setBusy('test'); setError(null); setTestResult(null);
    try {
      const res = await api.testDeliverability(domain.key, { kind, config });
      setTestResult({ ok: res.status === 'ok', message: res.message });
    } catch (e) {
      setTestResult({ ok: false, message: e?.message || 'Connection test failed.' });
    } finally { setBusy(null); }
  };

  if (loading) {
    return <div className={styles.section}><Spinner size={20} color="var(--violet)" /></div>;
  }

  return (
    <div className={styles.section}>
      <h2 className={styles.sectionTitle}>Deliverability</h2>
      <p className={deliv.intro}>
        Choose how mail from <strong>{domain.domain}</strong> goes out.
      </p>

      <div className={deliv.cards} role="radiogroup" aria-label="Deliverability provider">
        <ModeCard
          active={mode === BUILTIN}
          onSelect={() => { setMode(BUILTIN); setSavedOk(false); setTestResult(null); }}
          icon={<EspIcon icon="builtin" size={28} />}
          title="Inbox2 Deliverability"
          desc="We sign (DKIM) and deliver your mail. You set up nothing."
        />
        <ModeCard
          active={mode === CUSTOM}
          onSelect={() => { setMode(CUSTOM); setSavedOk(false); setTestResult(null); }}
          icon={<Icon name="arrow.triangle.branch" size={22} />}
          title="Bring your own ESP"
          desc="Send through Amazon SES, SendGrid, Mailgun, Postmark, Messy, or any SMTP provider."
        >
          {mode === CUSTOM && (
            <div className={deliv.custom} role="presentation" onClick={(e) => e.stopPropagation()}>
              <ProviderSelect providers={providers} value={kind} onChange={pickProvider} />
              {selected?.blurb && <p className={deliv.blurb}>{selected.blurb}</p>}
              <div className={deliv.fields}>
                {(selected?.fields || []).map((f) => (
                  <Field
                    key={f.key}
                    field={f}
                    value={config[f.key] ?? ''}
                    saved={savedFlags[`${f.key}_set`]}
                    onChange={(v) => setField(f.key, v)}
                  />
                ))}
              </div>
            </div>
          )}
        </ModeCard>
      </div>

      {testResult && (
        <p className={testResult.ok ? deliv.testOk : deliv.testErr} role="status">
          <Icon name={testResult.ok ? 'checkmark.circle.fill' : 'exclamationmark.triangle.fill'} size={13} />
          {testResult.message}
        </p>
      )}
      {error && (
        <p className={deliv.testErr} role="alert">
          <Icon name="exclamationmark.triangle.fill" size={13} /> {error}
        </p>
      )}

      <div className={deliv.actions}>
        {mode === CUSTOM && (
          <MgmtButton variant="glass" className={admin.modalCancel} onClick={test} disabled={busy !== null}>
            {busy === 'test' ? 'Testing…' : 'Test connection'}
          </MgmtButton>
        )}
        <MgmtButton variant="primary" onClick={save} disabled={busy !== null}>
          {busy === 'save' ? 'Saving…' : savedOk ? 'Saved ✓' : 'Save'}
        </MgmtButton>
      </div>
    </div>
  );
}

function ModeCard({ active, onSelect, icon, title, desc, children }) {
  return (
    <div
      className={[deliv.card, active ? deliv.cardOn : ''].join(' ')}
      role="radio"
      aria-checked={active}
      tabIndex={0}
      onClick={onSelect}
      onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onSelect(); } }}
    >
      <div className={deliv.cardHead}>
        <span className={deliv.cardIcon}>{icon}</span>
        <span className={deliv.cardTitle}>{title}</span>
        <span className={[deliv.radioDot, active ? deliv.radioDotOn : ''].join(' ')} aria-hidden />
      </div>
      <p className={deliv.cardDesc}>{desc}</p>
      {children}
    </div>
  );
}

/* Icon + name provider dropdown (native <select> can't render the brand mark). */
function ProviderSelect({ providers, value, onChange }) {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);
  const current = providers.find((p) => p.kind === value);

  useDismiss(ref, () => setOpen(false), open);

  return (
    <div className={deliv.select} ref={ref}>
      <button type="button" className={deliv.selectBtn} onClick={() => setOpen((o) => !o)} aria-haspopup="listbox" aria-expanded={open}>
        {current && <EspIcon icon={current.icon} size={22} />}
        <span className={deliv.selectLabel}>{current?.label || 'Choose a provider'}</span>
        <Icon name="chevron.up.chevron.down" size={13} />
      </button>
      {open && (
        <ul className={deliv.selectMenu} role="listbox">
          {providers.map((p) => (
            <li key={p.kind} role="option" aria-selected={p.kind === value}>
              <button
                type="button"
                className={[deliv.selectOpt, p.kind === value ? deliv.selectOptOn : ''].join(' ')}
                onClick={() => { onChange(p.kind); setOpen(false); }}
              >
                <EspIcon icon={p.icon} size={22} />
                <span>{p.label}</span>
                {p.kind === value && <Icon name="checkmark" size={13} />}
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function Field({ field, value, saved, onChange }) {
  const isSecret = field.type === 'password';
  return (
    <label className={admin.modalField}>
      <span className={admin.modalLabel}>
        {field.label}
        {!field.required && <span className={deliv.optional}> · optional</span>}
      </span>
      {field.type === 'select' ? (
        <MgmtSelect bare value={value} onChange={(e) => onChange(e.target.value)} options={field.options || []} />
      ) : (
        <input
          className={admin.modalInput}
          type={isSecret ? 'password' : 'text'}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder={isSecret && saved ? '•••••••••• (saved)' : field.placeholder || ''}
          autoComplete="off"
        />
      )}
      {isSecret && saved && <span className={deliv.savedHint}>A key is saved. Leave blank to keep it.</span>}
    </label>
  );
}
