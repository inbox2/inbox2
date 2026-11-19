import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router';
import api from '../../lib/api';
import { ManagementLayout, MgmtCard, MgmtField, MgmtSelect, MgmtStepper, MgmtButton, MgmtCheckbox } from '../../components/management';
import Icon from '../../components/Icon';
import styles from './WaitlistPage.module.css';

const INDUSTRIES = [
  { value: 'developer', label: 'Developer / Engineering' },
  { value: 'designer', label: 'Designer' },
  { value: 'founder', label: 'Founder / Owner' },
  { value: 'product', label: 'Product' },
  { value: 'marketing', label: 'Marketing' },
  { value: 'sales', label: 'Sales' },
  { value: 'support', label: 'Customer support' },
  { value: 'operations', label: 'Operations' },
  { value: 'agency', label: 'Agency / Consultancy' },
  { value: 'other', label: 'Other' },
];

// Brand icons shipped in ui/web/public/channels (same set the desktop app uses).
const EMAIL_PROVIDERS = [
  { key: 'gmail', label: 'Gmail / Google Workspace', icon: '/channels/gmail.svg' },
  { key: 'office365', label: 'Office 365 / Outlook', icon: '/channels/office365.svg' },
];
const SOCIAL_PROVIDERS = [
  { key: 'whatsapp', label: 'WhatsApp', icon: '/channels/whatsapp.svg' },
  { key: 'meta', label: 'Meta / Instagram', icon: '/channels/instagram.svg' },
  { key: 'messenger', label: 'Facebook Messenger', icon: '/channels/messenger.svg' },
];

const TURNSTILE_SRC = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// One provider row: icon + label + checkbox; ticking it reveals a +/- account
// counter (count 0 = unticked).
function ProviderRow({ icon, label, count, onChange }) {
  const checked = count > 0;
  return (
    <div className={styles.providerRow}>
      <label className={styles.providerMain}>
        <MgmtCheckbox  checked={checked} onChange={(e) => onChange(e.target.checked ? 1 : 0)} />
        <img src={icon} alt="" className={styles.providerIcon} />
        <span className={styles.providerLabel}>{label}</span>
      </label>
      {checked && (
        <MgmtStepper className={styles.providerStepper} value={count} onChange={(v) => onChange(v)} min={1} max={50} />
      )}
    </div>
  );
}

export default function WaitlistPage() {
  const [step, setStep] = useState(1);

  const [name, setName] = useState('');
  const [company, setCompany] = useState('');
  const [email, setEmail] = useState('');
  const [industry, setIndustry] = useState('');
  const [note, setNote] = useState('');

  const [emailCounts, setEmailCounts] = useState({ gmail: 0, office365: 0 });
  const [otherServices, setOtherServices] = useState([]);
  const [socialCounts, setSocialCounts] = useState({ whatsapp: 0, meta: 0, messenger: 0 });
  const [otherSocials, setOtherSocials] = useState([]);

  const [siteKey, setSiteKey] = useState(null);
  const [turnstileToken, setTurnstileToken] = useState('');
  const turnstileRef = useRef(null);

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [submitted, setSubmitted] = useState(false);

  // Public config (Turnstile site key) on mount.
  useEffect(() => {
    let active = true;
    api.waitlistConfig()
      .then((cfg) => { if (active) setSiteKey(cfg?.turnstile_site_key || null); })
      .catch(() => {});
    return () => { active = false; };
  }, []);

  // Render the Turnstile widget on step 2 once we have a site key.
  useEffect(() => {
    if (!siteKey || submitted || step !== 2) return undefined;

    let widgetId;
    const render = () => {
      if (!window.turnstile || !turnstileRef.current) return;
      widgetId = window.turnstile.render(turnstileRef.current, {
        sitekey: siteKey,
        theme: 'dark',
        callback: (token) => setTurnstileToken(token),
        'expired-callback': () => setTurnstileToken(''),
        'error-callback': () => setTurnstileToken(''),
      });
    };

    if (window.turnstile) {
      render();
    } else if (!document.querySelector(`script[src="${TURNSTILE_SRC}"]`)) {
      const script = document.createElement('script');
      script.src = TURNSTILE_SRC;
      script.async = true;
      script.defer = true;
      script.onload = render;
      document.head.appendChild(script);
    } else {
      document.querySelector(`script[src="${TURNSTILE_SRC}"]`).addEventListener('load', render);
    }

    return () => {
      if (widgetId && window.turnstile) window.turnstile.remove(widgetId);
    };
  }, [siteKey, submitted, step]);

  const addOther = (setter) => setter((list) => [...list, '']);
  const setOtherAt = (setter, i, value) => setter((list) => list.map((v, idx) => (idx === i ? value : v)));
  const removeOtherAt = (setter, i) => setter((list) => list.filter((_, idx) => idx !== i));

  const goNext = () => {
    setError('');
    if (!name.trim()) { setError('Enter your name.'); return; }
    if (!EMAIL_RE.test(email.trim())) { setError('Enter a valid email address.'); return; }
    setStep(2);
  };

  const goBack = () => { setError(''); setStep(1); };

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError('');

    if (siteKey && !turnstileToken) {
      setError('Complete the check first.');
      return;
    }

    setLoading(true);
    try {
      await api.waitlistSignup({
        name,
        company,
        email,
        industry,
        industry_note: note,
        email_services: {
          gmail_count: emailCounts.gmail,
          office365_count: emailCounts.office365,
          others: otherServices.map((s) => s.trim()).filter(Boolean),
        },
        social_accounts: {
          whatsapp_count: socialCounts.whatsapp,
          meta_count: socialCounts.meta,
          messenger_count: socialCounts.messenger,
          others: otherSocials.map((s) => s.trim()).filter(Boolean),
        },
        turnstile_token: turnstileToken,
      });
      setSubmitted(true);
    } catch (err) {
      setError(err?.data?.errors?.[0]?.message || err.message || 'Something went wrong. Try again.');
    } finally {
      setLoading(false);
    }
  };

  return (
    <ManagementLayout centered brand={false}>
      <MgmtCard className={styles.card}>
        <span className={styles.logo}>
          <img src="/logo-mark.png" alt="" />
          inbox2
        </span>

        {submitted ? (
          <div className={styles.done}>
            <div className={styles.doneIcon}><Icon name="checkmark.circle.fill" size={40} /></div>
            <h1 className={styles.title}>You're on the list</h1>
            <p className={styles.subtitle}>
              Thanks! We'll email you when your spot is ready.
            </p>
            <Link className={styles.link} to="/login">Already invited? Log in</Link>
          </div>
        ) : (
          <>
            <span className={styles.stepLabel}>Step {step} of 2</span>
            <h1 className={styles.title}>Request early access</h1>
            <p className={styles.subtitle}>
              {step === 1
                ? "inbox2 is invite-only while we roll out. Tell us a little about you."
                : 'Which channels does your team run on? Tick what you use.'}
            </p>
            {error && <div className={styles.error} role="alert">{error}</div>}

            <form className={styles.form} onSubmit={handleSubmit}>
              {step === 1 ? (
                <>
                  <MgmtField label="Your name" value={name} onChange={(e) => setName(e.target.value)} placeholder="Jane Doe" required autoFocus />
                  <MgmtField label="Company (optional)" value={company} onChange={(e) => setCompany(e.target.value)} placeholder="Acme Inc." />
                  <MgmtField label="Email address" type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="you@company.com" required />
                  <MgmtSelect label="What do you do?" value={industry} onChange={(e) => setIndustry(e.target.value)} placeholder="Select one…" options={INDUSTRIES} />
                  <MgmtButton type="button" variant="primary" block onClick={goNext}>
                    Next <Icon name="arrow.right" size={14} />
                  </MgmtButton>
                </>
              ) : (
                <>
                  <fieldset className={styles.section}>
                    <legend className={styles.sectionTitle}>Which email services do you use?</legend>
                    <div className={styles.countHeader}><span>How many?</span></div>
                    {EMAIL_PROVIDERS.map((p) => (
                      <ProviderRow
                        key={p.key}
                        icon={p.icon}
                        label={p.label}
                        count={emailCounts[p.key]}
                        onChange={(v) => setEmailCounts((c) => ({ ...c, [p.key]: v }))}
                      />
                    ))}
                    {otherServices.map((value, i) => (
                      <div key={i} className={styles.otherRow}>
                        <input className={styles.otherInput} value={value} onChange={(e) => setOtherAt(setOtherServices, i, e.target.value)} placeholder="Other (say which)" />
                        <button type="button" className={styles.removeBtn} onClick={() => removeOtherAt(setOtherServices, i)} aria-label="Remove">×</button>
                      </div>
                    ))}
                    <button type="button" className={styles.addBtn} onClick={() => addOther(setOtherServices)}>+ Add other</button>
                  </fieldset>

                  <fieldset className={styles.section}>
                    <legend className={styles.sectionTitle}>Social business accounts</legend>
                    <div className={styles.countHeader}><span>How many?</span></div>
                    {SOCIAL_PROVIDERS.map((p) => (
                      <ProviderRow
                        key={p.key}
                        icon={p.icon}
                        label={p.label}
                        count={socialCounts[p.key]}
                        onChange={(v) => setSocialCounts((c) => ({ ...c, [p.key]: v }))}
                      />
                    ))}
                    {otherSocials.map((value, i) => (
                      <div key={i} className={styles.otherRow}>
                        <input className={styles.otherInput} value={value} onChange={(e) => setOtherAt(setOtherSocials, i, e.target.value)} placeholder="Other (say which)" />
                        <button type="button" className={styles.removeBtn} onClick={() => removeOtherAt(setOtherSocials, i)} aria-label="Remove">×</button>
                      </div>
                    ))}
                    <button type="button" className={styles.addBtn} onClick={() => addOther(setOtherSocials)}>+ Add other</button>
                  </fieldset>

                  <MgmtField label="What are you hoping inbox2 does for your team? (optional)" value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. one inbox for sales@ and support@" maxLength={2000} />

                  <div className={styles.actions}>
                    <MgmtButton type="button" variant="glass" onClick={goBack}>Back</MgmtButton>
                    <MgmtButton type="submit" variant="primary" disabled={loading}>
                      {loading ? 'Submitting…' : (<>Request access <Icon name="arrow.right" size={14} /></>)}
                    </MgmtButton>
                  </div>
                </>
              )}
            </form>

            <div className={styles.footer}>
              <span className={styles.muted}>Already invited? <Link className={styles.link} to="/login">Log in</Link></span>
            </div>

            {step === 2 && siteKey && <div ref={turnstileRef} className={styles.turnstile} />}
          </>
        )}
      </MgmtCard>
    </ManagementLayout>
  );
}
