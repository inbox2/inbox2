// Per-channel open-tracking control for a connected local account
// (docs/Open-Tracking.md). Desktop-only (Tauri): reads/writes the engine's
// per-account open_tracking_enabled + track_domain. Mail providers only.
import { useEffect, useState } from 'react';
import Icon from '../Icon';
import DnsRecordsTable from '../DnsRecordsTable/DnsRecordsTable';
import api from '../../lib/api';
import log from '../../lib/log';
import { isTauri } from '../../lib/tauri';
import styles from './AccountTracking.module.css';

const MAIL_PROVIDERS = new Set(['gmail', 'microsoft', 'office365', 'imap']);

// Recommend a subdomain of the channel's OWN sending domain (track.tuli.com for
// waseem@tuli.com). A pixel host on a different registrable domain than the From
// address raises spam scoring — same-domain keeps it clean.
function suggestedHost(email) {
  const domain = String(email || '').split('@')[1]?.toLowerCase().trim();
  return domain ? `track.${domain}` : 'track.yourdomain.com';
}

export default function AccountTracking({ account }) {
  const [enabled, setEnabled] = useState(false);
  const [trackDomain, setTrackDomain] = useState('');
  const [custom, setCustom] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [busy, setBusy] = useState(false);
  // Registration (CF-for-SaaS TLS + the DNS record to add) for the saved custom host.
  const [reg, setReg] = useState(null);
  const [checkMsg, setCheckMsg] = useState(null);

  // Available only with a cloud identity (mx session or ink_ token) — that's how
  // the config is saved/synced across devices (docs/Open-Tracking.md). On desktop
  // a truthy bearer means signed-in.
  const [available, setAvailable] = useState(false);

  const key = account?.key;
  const email = account?.email_address;
  const supported = isTauri() && MAIL_PROVIDERS.has(account?.provider_type);

  useEffect(() => {
    let cancelled = false;
    if (!supported || !key) return undefined;
    (async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core');
        const cloudAuthed = !!(await api.getToken());
        if (cancelled) return;
        setAvailable(cloudAuthed);

        // Cloud is the source of truth; fall back to the local mirror if offline.
        let s = null;
        if (cloudAuthed) {
          try {
            const { channels } = await api.getChannelTracking();
            s = channels?.find((c) => String(c.email_address).toLowerCase() === String(email).toLowerCase()) || null;
            if (s) await invoke('set_open_tracking', { accountKey: key, enabled: !!s.open_tracking_enabled, trackDomain: s.track_domain || null });
          } catch { /* fall through to local */ }
        }
        if (!s) s = await invoke('get_open_tracking', { accountKey: key });
        if (cancelled) return;
        setEnabled(!!(s.open_tracking_enabled ?? s.enabled));
        setTrackDomain(s.track_domain || '');
        setCustom(!!s.track_domain);
      } catch (e) {
        log.warn('OpenTracking', `load failed: ${e?.message || e}`);
      } finally {
        if (!cancelled) setLoaded(true);
      }
    })();
    return () => { cancelled = true; };
  }, [supported, key, email]);

  // Write both the local engine mirror (drives injection) AND the cloud record
  // (syncs to the user's other devices).
  const save = async (next) => {
    setBusy(true);
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('set_open_tracking', { accountKey: key, enabled: next.enabled, trackDomain: next.trackDomain || null });
      await api.setChannelTracking({ email, open_tracking_enabled: next.enabled, track_domain: next.trackDomain || '' })
        .catch((e) => log.warn('OpenTracking', `cloud save failed: ${e?.message || e}`));
    } catch (e) {
      log.warn('OpenTracking', `save failed: ${e?.message || e}`);
    } finally {
      setBusy(false);
    }
  };

  if (!supported || !loaded) return null;

  if (!available) {
    return (
      <div className={styles.wrap}>
        <span className={styles.title}><Icon name="eye.fill" size={12} /> Open tracking</span>
        <p className={styles.hint}>Link your inbox2 account in Settings → Cloud proxy to track opens. It works on all your devices.</p>
      </div>
    );
  }

  const toggle = () => {
    const v = !enabled;
    setEnabled(v);
    save({ enabled: v, trackDomain: custom ? trackDomain.trim() : '' });
  };

  const chooseInbox2 = () => { setCustom(false); setReg(null); setCheckMsg(null); save({ enabled, trackDomain: '' }); };

  // Save the host locally AND provision its CF-for-SaaS TLS + fetch the DNS record.
  const saveHost = async () => {
    const host = trackDomain.trim();
    if (!host) return;
    setCheckMsg(null);
    await save({ enabled, trackDomain: host });
    try { setReg(await api.registerTrackingHost(host)); }
    catch (e) { log.warn('OpenTracking', `register failed: ${e?.message || e}`); }
  };

  const verify = async () => {
    setBusy(true); setCheckMsg(null);
    try {
      const res = await api.verifyTrackingHost(trackDomain.trim());
      setReg(res);
      setCheckMsg(res.verified
        ? { ok: true, text: 'Verified. Opens now track from your own domain.' }
        : { ok: false, text: res.dns?.error || 'Not verified yet. Add the CNAME (DNS-only) and give DNS a few minutes.' });
    } catch (e) {
      setCheckMsg({ ok: false, text: e?.message || 'Couldn’t verify. Try again.' });
    } finally { setBusy(false); }
  };

  return (
    <div className={styles.wrap}>
      <div className={styles.head}>
        <span className={styles.title}>
          <Icon name="eye.fill" size={12} /> Open tracking
        </span>
        <button
          type="button"
          className={[styles.toggle, enabled ? styles.on : ''].join(' ')}
          onClick={toggle}
          disabled={busy}
          role="switch"
          aria-checked={enabled}
          aria-label="Open tracking"
        />
      </div>

      {enabled && (
        <div className={styles.body}>
          <label className={styles.choice}>
            <input type="radio" checked={!custom} onChange={chooseInbox2} disabled={busy} />
            <span>Use inbox2 domain (no setup)</span>
          </label>
          <label className={styles.choice}>
            <input type="radio" checked={custom} onChange={() => { setCustom(true); if (!trackDomain) setTrackDomain(suggestedHost(account.email_address)); }} disabled={busy} />
            <span>A subdomain of your sending domain (recommended)</span>
          </label>
          {custom && (
            <div className={styles.hostRow}>
              <input
                className={styles.input}
                type="text"
                placeholder={suggestedHost(account.email_address)}
                value={trackDomain}
                onChange={(e) => setTrackDomain(e.target.value)}
                disabled={busy}
                autoCapitalize="off"
                autoCorrect="off"
                spellCheck={false}
              />
              <button type="button" className={styles.save} onClick={saveHost} disabled={busy || !trackDomain.trim()}>
                Save
              </button>
            </div>
          )}
          {custom && (
            <p className={styles.hint}>
              Spam filters trust a pixel on your own domain more than a shared one.
            </p>
          )}

          {custom && reg?.records?.length > 0 && (
            <div className={styles.dns}>
              <p className={styles.hint}>
                Add this <strong>DNS-only</strong> CNAME for <strong>{reg.host}</strong> (→ {reg.cname_target}). On Cloudflare, keep the cloud <strong>grey</strong>, or you&apos;ll lose opens.
              </p>
              <DnsRecordsTable records={reg.records} verified={() => (reg.verified ? true : null)} />
              <div className={styles.verifyRow}>
                <button type="button" className={styles.save} onClick={verify} disabled={busy}>
                  {busy ? 'Checking…' : 'Verify now'}
                </button>
                {!reg.cloudflare_saas && (
                  <span className={styles.hint}>Custom hosts don’t have HTTPS here yet.</span>
                )}
              </div>
              {checkMsg && (
                <p className={checkMsg.ok ? styles.okMsg : styles.hint} role="status">{checkMsg.text}</p>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
