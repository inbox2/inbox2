import { useState, useEffect, useCallback } from 'react';
import Icon from '../../components/Icon';
import Spinner from '../../components/Spinner';
import { MgmtModal, MgmtButton } from '../../components/management';
import SecretValue from '../../components/SecretValue';
import useAuth from '../../hooks/useAuth';
import { initialsDataUri } from '../../lib/initialsIcon';
import api from '../../lib/api';
import log from '../../lib/log';
import styles from './console.module.css';
import admin from './adminShared.module.css';
import local from './ConsoleApplications.module.css';

/* Applications — third-party apps allowed to broker Google / Microsoft 365
 * OAuth through inbox2 (docs/App-OAuth.md). The name + icon registered here are
 * what the person granting access sees on the consent screen, so this page is
 * as much branding as it is configuration. */

export default function ConsoleApplications() {
  const { organizations, currentOrg } = useAuth();
  const orgId = currentOrg?.id || organizations?.[0]?.id;

  const [apps, setApps] = useState(null); // null = loading
  const [error, setError] = useState('');
  const [editing, setEditing] = useState(null); // app object, or {} for a new one
  const [removing, setRemoving] = useState(null);
  const [removeBusy, setRemoveBusy] = useState(false);

  const load = useCallback(() => {
    if (!orgId) return;
    api.listOauthApps(orgId)
      .then((res) => setApps(res.oauth_apps || []))
      .catch((e) => {
        log.warn('Applications', `load failed: ${e?.message || e}`);
        setApps([]);
        setError("Couldn't load your applications.");
      });
  }, [orgId]);

  useEffect(() => { load(); }, [load]);

  const confirmRemove = useCallback(async () => {
    if (!removing) return;
    setRemoveBusy(true);
    try {
      await api.deleteOauthApp(orgId, removing.id);
      setApps((prev) => (prev || []).filter((a) => a.id !== removing.id));
      setRemoving(null);
    } catch (e) {
      setError(e?.message || "Couldn't delete the application.");
    } finally {
      setRemoveBusy(false);
    }
  }, [removing, orgId]);

  return (
    <>
      <div className={styles.pageHead}>
        <div>
          <div className={styles.pageEyebrow}>Developers</div>
          <h1 className={styles.pageTitle}>Applications</h1>
          <p className={styles.pageSub}>
            Let your app connect Google or Microsoft 365 mailboxes through inbox2.
          </p>
        </div>
        <div className={styles.pageActions}>
          <MgmtButton variant="primary" onClick={() => setEditing({})} disabled={!orgId}>
            <Icon name="plus" size={14} /> Register application
          </MgmtButton>
        </div>
      </div>

      <div className={styles.card}>
        {apps === null ? (
          <div className={styles.cardLoading}><Spinner size={18} color="#2f7ad6" /></div>
        ) : apps.length === 0 ? (
          <div className={local.empty}>
            <Icon name="macwindow" size={26} />
            <p className={local.emptyTitle}>No applications registered</p>
            <p className={local.emptySub}>
              Register one to connect mailboxes with an inbox2 API key.
            </p>
          </div>
        ) : (
          <table className={styles.tbl}>
            <thead>
              <tr>
                <th>Application</th>
                <th>Application ID</th>
                <th>Callback URLs</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {apps.map((app) => (
                <tr key={app.id}>
                  <td>
                    <span className={styles.domainCell}>
                      <img className={styles.favicon} src={app.icon_url || initialsDataUri(app.name)} alt="" />
                      {app.name}
                    </span>
                  </td>
                  <td>
                    <SecretValue value={app.id} label="application ID" />
                  </td>
                  <td>
                    <ul className={local.uriList}>
                      {app.redirect_uris.map((uri) => <li key={uri}>{uri}</li>)}
                    </ul>
                  </td>
                  <td className={styles.right}>
                    <span className={styles.ruleActions}>
                      <MgmtButton variant="glass" size="sm" onClick={() => setEditing(app)}>
                        <Icon name="gear" size={12} /> Edit
                      </MgmtButton>
                      <button
                        type="button"
                        className={styles.rowRemove}
                        onClick={() => setRemoving(app)}
                        title={`Delete ${app.name}`}
                        aria-label={`Delete ${app.name}`}
                      >
                        <Icon name="trash" size={13} />
                      </button>
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        {error && (
          <p className={`${admin.settingsError} ${local.error}`} role="alert">
            <Icon name="exclamationmark.triangle" size={14} /> {error}
          </p>
        )}
      </div>

      <div className={`${styles.card} ${local.howto}`}>
        <h2 className={styles.cardTitle}>Starting a flow</h2>
        <p className={local.howtoSub}>
          Your app&apos;s server opens the flow with an inbox2 API key (create one under
          <strong> API keys &amp; devices</strong>), sends the person to the returned URL, then redeems
          the mailbox credential once they come back.
        </p>
        <pre className={local.code}>{`POST /api/v1/auth/app-oauth/authorize
  Authorization: Bearer ink_…
  { "app": "oap_…", "provider": "google", "redirect_uri": "…", "state": "…" }
→ { "authorize_url": "…", "flow": "oag_…" }

# after the person returns to your redirect_uri with ?flow=oag_…
POST /api/v1/auth/app-oauth/token
  Authorization: Bearer ink_…
  { "flow": "oag_…" }
→ { "credential": { "provider", "email", "access_token", "refresh_token", … } }`}</pre>
      </div>

      {editing && (
        <AppModal
          orgId={orgId}
          app={editing.id ? editing : null}
          onClose={() => setEditing(null)}
          onSaved={() => { setEditing(null); load(); }}
        />
      )}

      {removing && (
        <MgmtModal open onClose={() => (removeBusy ? null : setRemoving(null))} width={520}>
          <h2 className={admin.modalTitle}>Delete {removing.name}?</h2>
          <p className={admin.modalSub}>
            Any flow started by <strong>{removing.name}</strong> stops working right away. Mailboxes
            it already connected keep working.
          </p>
          <div className={admin.modalActions}>
            <MgmtButton variant="glass" className={admin.modalCancel} onClick={() => setRemoving(null)} disabled={removeBusy}>
              Cancel
            </MgmtButton>
            <MgmtButton variant="danger" onClick={confirmRemove} disabled={removeBusy}>
              {removeBusy ? 'Deleting…' : 'Delete application'}
            </MgmtButton>
          </div>
        </MgmtModal>
      )}
    </>
  );
}

/* Register / edit. The icon is a second request (it needs an application to
 * attach to), so a new app is created first and then given its icon. */
function AppModal({ orgId, app, onClose, onSaved }) {
  const [name, setName] = useState(app?.name || '');
  const [uris, setUris] = useState((app?.redirect_uris || []).join('\n'));
  const [iconFile, setIconFile] = useState(null);
  const [iconPreview, setIconPreview] = useState(app?.icon_url || '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const pickIcon = (e) => {
    const file = e.target.files?.[0];
    if (!file) return;
    setIconFile(file);
    setIconPreview(URL.createObjectURL(file));
  };

  const save = async () => {
    const trimmed = name.trim();
    const redirect_uris = uris.split(/\r?\n/).map((u) => u.trim()).filter(Boolean);
    if (!trimmed || redirect_uris.length === 0 || busy) {
      setError('Add a name and at least one callback URL.');
      return;
    }
    setBusy(true);
    setError('');
    try {
      const res = app
        ? await api.updateOauthApp(orgId, app.id, { name: trimmed, redirect_uris })
        : await api.createOauthApp(orgId, { name: trimmed, redirect_uris });
      if (iconFile) await api.uploadOauthAppIcon(orgId, res.oauth_app.id, iconFile);
      onSaved();
    } catch (e) {
      setError(e?.data?.errors?.[0]?.message || e?.message || "Couldn't save the application.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <MgmtModal open onClose={() => (busy ? null : onClose())} width={620}>
      <h2 className={admin.modalTitle}>{app ? `Edit ${app.name}` : 'Register application'}</h2>
      <p className={admin.modalSub}>
        People see this name and icon when they are asked to connect their mailbox.
      </p>

      <div className={admin.modalField}>
        <span className={admin.modalLabel}>Name</span>
        <input
          className={admin.modalInput}
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="e.g. Acme CRM"
          autoComplete="off"
        />
      </div>

      <div className={admin.modalField}>
        <span className={admin.modalLabel}>Icon</span>
        <div className={local.iconRow}>
          <img className={local.iconPreview} src={iconPreview || initialsDataUri(name || '?')} alt="" />
          <label className={local.iconPick}>
            <input type="file" accept="image/png,image/jpeg,image/gif,image/webp" onChange={pickIcon} />
            <span><Icon name="photo" size={13} /> Choose image</span>
          </label>
          <span className={local.iconHint}>Square PNG, JPEG, GIF or WebP · under 2MB</span>
        </div>
      </div>

      <div className={admin.modalField}>
        <span className={admin.modalLabel}>Callback URLs</span>
        <textarea
          className={`${admin.modalInput} ${local.uriBox}`}
          value={uris}
          onChange={(e) => setUris(e.target.value)}
          placeholder={'https://app.example.com/oauth/inbox2\nhttps://staging.example.com/oauth/inbox2'}
          rows={4}
        />
        <span className={local.iconHint}>
          One per line, one for each environment. Use https (http works on localhost).
          Sign-ins only return to these addresses.
        </span>
      </div>

      {error && <p className={admin.modalError} role="alert">{error}</p>}

      <div className={admin.modalActions}>
        <MgmtButton variant="glass" className={admin.modalCancel} onClick={onClose} disabled={busy}>Cancel</MgmtButton>
        <MgmtButton variant="primary" onClick={save} disabled={busy}>
          {busy ? 'Saving…' : app ? 'Save changes' : 'Register'}
        </MgmtButton>
      </div>
    </MgmtModal>
  );
}
