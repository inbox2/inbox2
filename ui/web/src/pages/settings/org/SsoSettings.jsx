import { useCallback, useEffect, useState } from 'react';
import api from '../../../lib/api';
import log from '../../../lib/log';
import useUndoStore from '../../../stores/undoStore';
import Button from '../../../components/Button/Button';
import Checkbox from '../../../components/Checkbox/Checkbox';
import ConfirmDialog from '../../../components/ConfirmDialog/ConfirmDialog';
import styles from '../settings.module.css';

const EMPTY = { idp_entity_id: '', idp_sso_url: '', idp_certificate: '', enabled: false };

/* Single sign-on (SAML, spec 2.1.7). Two halves: the org's IdP configuration
 * (admins; the certificate is write-only, the API never echoes it) and the
 * signed-in member's own identity link — SSO never matches people by name, so
 * an existing member links once, through their IdP, before SSO can log them in. */
export default function SsoSettings({ orgId }) {
  const [config, setConfig] = useState(null);     // null = not configured
  const [form, setForm] = useState(EMPTY);
  const [identity, setIdentity] = useState(null);
  const [busy, setBusy] = useState(false);
  const [confirmRemove, setConfirmRemove] = useState(false);
  const notify = useUndoStore((s) => s.notify);

  const load = useCallback(() => {
    if (!orgId) return Promise.resolve();
    return Promise.all([api.samlConfig(orgId), api.samlIdentity(orgId)])
      .then(([{ saml_config: cfg }, { saml_identity: me }]) => {
        setConfig(cfg);
        setForm(cfg ? { ...EMPTY, idp_entity_id: cfg.idp_entity_id || '', idp_sso_url: cfg.idp_sso_url || '', enabled: !!cfg.enabled } : EMPTY);
        setIdentity(me);
      })
      .catch((e) => log.warn('SSO', `load failed: ${e?.message || e}`));
  }, [orgId]);

  useEffect(() => { load(); }, [load]);

  const fail = (what, e) => {
    log.error('SSO', `${what}: ${e?.message || e}`);
    notify({ description: `${what}. ${e?.message || 'Try again.'}`, variant: 'danger', icon: 'exclamationmark.triangle' });
  };

  const save = async () => {
    setBusy(true);
    try {
      // Only send the certificate when one was pasted; blank means "keep the stored one".
      const params = { idp_entity_id: form.idp_entity_id, idp_sso_url: form.idp_sso_url, enabled: form.enabled };
      if (form.idp_certificate.trim()) params.idp_certificate = form.idp_certificate.trim();
      await api.saveSamlConfig(orgId, params);
      notify({ description: 'Single sign-on settings saved.', icon: 'checkmark.circle' });
      await load();
    } catch (e) {
      fail("Couldn't save the SSO settings", e);
    } finally {
      setBusy(false);
    }
  };

  const remove = async () => {
    setConfirmRemove(false);
    setBusy(true);
    try {
      await api.deleteSamlConfig(orgId);
      setConfig(null);
      setForm(EMPTY);
    } catch (e) {
      fail("Couldn't remove the SSO settings", e);
    } finally {
      setBusy(false);
    }
  };

  const link = async () => {
    setBusy(true);
    try {
      const { redirect_url: url } = await api.samlLink(orgId);
      window.location.assign(url);
    } catch (e) {
      fail("Couldn't start the SSO link", e);
      setBusy(false);
    }
  };

  const unlink = async () => {
    setBusy(true);
    try {
      await api.samlUnlink(orgId);
      setIdentity(null);
    } catch (e) {
      fail("Couldn't unlink", e);
    } finally {
      setBusy(false);
    }
  };

  const set = (key) => (e) => setForm((f) => ({ ...f, [key]: e.target.value }));
  // Absolute: the IdP admin pastes this; in dev the API base is a relative proxy path.
  const metadataUrl = new URL(`${api.baseUrl}/orgs/${orgId}/saml/metadata`, window.location.origin).href;

  return (
    <>
      <div className={styles.settingsTitleRow}>
        <h1 className={styles.settingsTitle}>Single sign-on</h1>
      </div>

      <div className={styles.settingsSection}>
        <div className={styles.settingsSectionTitle}>Your identity</div>
        {identity ? (
          <>
            <div className={styles.settingsField}>
              <label>Linked as</label>
              <input value={identity.name_id} disabled />
            </div>
            <Button variant="secondary" className={styles.settingsButton} disabled={busy} onClick={unlink}>Unlink</Button>
          </>
        ) : (
          <>
            <p className={styles.settingsHint}>
              {config?.enabled
                ? 'Link your account to your identity provider once; after that "Sign in with SSO" logs you straight in.'
                : 'Once an admin enables SSO below, link your account here.'}
            </p>
            <Button className={styles.settingsButton} disabled={busy || !config?.enabled} onClick={link}>Link my SSO identity</Button>
          </>
        )}
      </div>

      <div className={styles.settingsSection}>
        <div className={styles.settingsSectionTitle}>Identity provider (admins)</div>
        <div className={styles.settingsField}>
          <label htmlFor="sso-entity">IdP entity ID</label>
          <input id="sso-entity" value={form.idp_entity_id} onChange={set('idp_entity_id')} placeholder="https://idp.example.com/saml" />
        </div>
        <div className={styles.settingsField}>
          <label htmlFor="sso-url">IdP SSO URL</label>
          <input id="sso-url" value={form.idp_sso_url} onChange={set('idp_sso_url')} placeholder="https://idp.example.com/sso" />
        </div>
        <div className={styles.settingsField}>
          <label htmlFor="sso-cert">IdP signing certificate (PEM){config ? ' — leave blank to keep the stored one' : ''}</label>
          <textarea id="sso-cert" value={form.idp_certificate} onChange={set('idp_certificate')} placeholder="-----BEGIN CERTIFICATE-----" />
        </div>
        <div className={styles.settingsField}>
          <Checkbox checked={form.enabled} onChange={(e) => setForm((f) => ({ ...f, enabled: e.target.checked }))}>
            Enable single sign-on for this organization
          </Checkbox>
        </div>
        <div className={styles.settingsField}>
          <label>Service-provider metadata (give this to your IdP)</label>
          <span className={styles.settingsHint}>{metadataUrl}</span>
        </div>
        <div className={styles.settingsModalActions}>
          {config && <Button variant="secondary" disabled={busy} onClick={() => setConfirmRemove(true)}>Remove</Button>}
          <Button disabled={busy || !form.idp_entity_id.trim() || !form.idp_sso_url.trim() || (!config && !form.idp_certificate.trim())} onClick={save}>
            {config ? 'Save' : 'Set up SSO'}
          </Button>
        </div>
      </div>

      <ConfirmDialog
        open={confirmRemove}
        title="Remove single sign-on?"
        message="Members will sign in with their inbox2 password again. Linked identities are kept."
        confirmLabel="Remove"
        onConfirm={remove}
        onCancel={() => setConfirmRemove(false)}
      />
    </>
  );
}
