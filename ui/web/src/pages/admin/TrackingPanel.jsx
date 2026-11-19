// Open-tracking settings tab (docs/Open-Tracking.md): the per-domain (MX) opt-in,
// the "inbox2 host vs custom subdomain" choice, and the custom-host DNS setup —
// a single DNS-only CNAME + a live Verify that surfaces the Cloudflare
// orange-cloud conflict (the record must be grey-cloud / DNS-only).
import { useCallback, useEffect, useState } from 'react';
import Icon from '../../components/Icon';
import Spinner from '../../components/Spinner';
import { MgmtButton } from '../../components/management';
import DnsRecordsTable from '../../components/DnsRecordsTable/DnsRecordsTable';
import api from '../../lib/api';
import log from '../../lib/log';
import admin from './adminShared.module.css';
import styles from './DomainSettingsPage.module.css';
import css from './TrackingPanel.module.css';

export default function TrackingPanel({ domain }) {
  const orgKey = domain.key;
  const [rec, setRec] = useState(null);        // the Domain row (id = domain key)
  const [state, setState] = useState(null);    // GET .../tracking payload
  const [custom, setCustom] = useState(false); // "custom subdomain" chosen
  const [host, setHost] = useState('');
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [checkMsg, setCheckMsg] = useState(null); // { ok, text } from Verify

  const apply = (payload) => {
    setState(payload);
    setCustom(!!payload.tracking_domain);
    setHost(payload.tracking_domain || '');
  };

  const reload = useCallback(async () => {
    try {
      const domains = (await api.listDomains(orgKey)).domains || [];
      const found = domains.find((d) => d.name === domain.domain) || domains[0];
      setRec(found || null);
      if (found) apply(await api.getDomainTracking(orgKey, found.id));
    } catch (e) {
      log.warn('Tracking', `load failed: ${e?.message || e}`);
      setError("Couldn't load open-tracking settings.");
    } finally {
      setLoading(false);
    }
  }, [orgKey, domain.domain]);

  useEffect(() => {
    let cancelled = false;
    Promise.resolve().then(() => { if (!cancelled) reload(); });
    return () => { cancelled = true; };
  }, [reload]);

  const run = async (fn) => {
    setBusy(true); setError(null);
    try { await fn(); } catch (e) {
      log.warn('Tracking', e?.message || e);
      setError(e?.message || 'Something went wrong.');
    } finally { setBusy(false); }
  };

  const patch = (body) => run(async () => { apply(await api.updateDomainTracking(orgKey, rec.id, body)); });

  const toggleOpen = () => patch({ open_tracking_enabled: !state.open_tracking_enabled });
  const toggleLink = () => patch({ link_tracking_enabled: !state.link_tracking_enabled });

  const chooseInbox2 = () => { setCustom(false); setCheckMsg(null); if (state.tracking_domain) patch({ tracking_domain: '' }); };

  const saveHost = () => run(async () => {
    setCheckMsg(null);
    apply(await api.updateDomainTracking(orgKey, rec.id, { tracking_domain: host.trim() }));
  });

  const verify = () => run(async () => {
    const res = await api.verifyDomainTracking(orgKey, rec.id);
    apply(res);
    if (res.verified) setCheckMsg({ ok: true, text: `Verified. We track opens from ${res.tracking_host}.` });
    else setCheckMsg({ ok: false, text: res.dns?.error || 'Not verified yet. Add the CNAME (DNS-only) and give DNS a few minutes.' });
  });

  if (loading) return <div className={styles.loading}><Spinner size={22} color="var(--violet)" /></div>;
  if (!state) return <p className={admin.settingsError}>Open tracking is unavailable for this domain.</p>;

  const on = state.open_tracking_enabled;
  const linkOn = state.link_tracking_enabled;
  const suggested = `track.${domain.domain}`;

  return (
    <div className={styles.section}>
      <h2 className={styles.sectionTitle}>Email tracking</h2>
      <div className={admin.modalField}>
        <span className={admin.modalLabel}>Open tracking</span>
        <div className={admin.settingsAssetRow}>
          <button
            type="button"
            className={[styles.trackToggle, on ? '' : styles.trackToggleOff].join(' ')}
            onClick={toggleOpen}
            disabled={busy}
            role="switch"
            aria-checked={on}
            aria-label="Open tracking"
          />
          <span className={admin.settingsHint}>
            {on
              ? 'On. We add a tracking pixel to mail from this domain and record each open.'
              : 'Off. Mail goes out without a tracking pixel.'}
          </span>
        </div>
      </div>

      <div className={admin.modalField}>
        <span className={admin.modalLabel}>Link tracking</span>
        <div className={admin.settingsAssetRow}>
          <button
            type="button"
            className={[styles.trackToggle, linkOn ? '' : styles.trackToggleOff].join(' ')}
            onClick={toggleLink}
            disabled={busy}
            role="switch"
            aria-checked={linkOn}
            aria-label="Link tracking"
          />
          <span className={admin.settingsHint}>
            {linkOn
              ? 'On. We route links through a redirect and record each click.'
              : 'Off. Links go out as you wrote them.'}
          </span>
        </div>
      </div>

      {(on || linkOn) && (
        <div className={admin.modalField}>
          <span className={admin.modalLabel}>Tracking domain</span>

          <label className={[admin.choice, !custom ? admin.choiceOn : ''].join(' ')}>
            <input type="radio" className={admin.choiceRadio} checked={!custom} onChange={chooseInbox2} disabled={busy} />
            <span className={admin.choiceText}>
              <span className={admin.choiceTitle}>Use inbox2 ({state.default_host})</span>
              <span className={admin.choiceDesc}>No DNS setup. The pixel loads from inbox2’s domain.</span>
            </span>
          </label>

          <label className={[admin.choice, custom ? admin.choiceOn : ''].join(' ')}>
            <input type="radio" className={admin.choiceRadio} checked={custom} onChange={() => setCustom(true)} disabled={busy} />
            <span className={admin.choiceText}>
              <span className={admin.choiceTitle}>Custom domain</span>
              <span className={admin.choiceDesc}>
                Load the pixel from a subdomain of your sending domain, like <code>{suggested}</code>.
              </span>
            </span>
          </label>

          {custom && (
            <div className={css.hostRow}>
              <input
                className={[admin.modalInput, css.hostInput].join(' ')}
                type="text"
                value={host}
                placeholder={suggested}
                onChange={(e) => setHost(e.target.value)}
                disabled={busy}
                autoCapitalize="off"
                autoCorrect="off"
                spellCheck={false}
              />
              <MgmtButton variant="primary" onClick={saveHost} disabled={busy || !host.trim() || host.trim() === state.tracking_domain}>
                Save
              </MgmtButton>
            </div>
          )}

          {custom && state.tracking_domain && (
            <div className={[admin.dns, css.dnsBlock].join(' ')}>
              <p className={[admin.settingsHint, css.dnsIntro].join(' ')}>
                Add this record at your DNS provider for <strong>{state.tracking_domain}</strong>, then verify. It must be{' '}
                <strong>DNS-only</strong>. On Cloudflare, keep the cloud <strong>grey</strong> or you lose opens.
              </p>
              <DnsRecordsTable records={state.records} verified={() => (state.verified ? true : null)} />

              <div className={css.verifyRow}>
                <MgmtButton variant="secondary" onClick={verify} disabled={busy}>
                  {busy ? 'Checking…' : 'Verify now'}
                </MgmtButton>
                {state.verified && (
                  <span className={admin.dnsOk}><Icon name="checkmark.seal.fill" size={14} /> Verified</span>
                )}
                {!state.cloudflare_saas && (
                  <span className={admin.settingsHint}>
                    HTTPS for custom tracking domains isn’t set up here yet.
                  </span>
                )}
              </div>

              {checkMsg && (
                <p className={checkMsg.ok ? admin.dnsOk : admin.settingsError} role="status">
                  <Icon name={checkMsg.ok ? 'checkmark.circle.fill' : 'exclamationmark.triangle.fill'} size={13} /> {checkMsg.text}
                </p>
              )}
            </div>
          )}
        </div>
      )}

      {error && (
        <p className={admin.settingsError} role="alert">
          <Icon name="exclamationmark.triangle.fill" size={13} /> {error}
        </p>
      )}
    </div>
  );
}
