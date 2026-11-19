// E2EE settings tab (docs/E2EE.md Phase F): identity setup with the recovery
// passphrase HARD save-gate, domain key minting + grants, the enable/disable
// switch, and the member grant table. All crypto is client-side (lib/e2ee.js);
// the server only ever receives opaque blobs.
import { useCallback, useEffect, useMemo, useState } from 'react';
import Icon from '../../components/Icon';
import Spinner from '../../components/Spinner';
import { MgmtButton, MgmtCheckbox } from '../../components/management';
import api from '../../lib/api';
import log from '../../lib/log';
import { ready, generateDomainKey, sealGrant, normalizePassphrase } from '../../lib/e2ee';
import { useE2ee, refreshIdentity, setupIdentity, unlock, isUnlocked, loadDomainSecret } from '../../lib/e2eeStore';
import admin from './adminShared.module.css';
import styles from './DomainSettingsPage.module.css';
import e2ee from './E2eePanel.module.css';

export default function E2eePanel({ domain }) {
  const session = useE2ee();
  const [record, setRecord] = useState(null); // the Domain row (key, name, e2ee_enabled)
  const [stateData, setStateData] = useState(null); // GET .../e2ee payload
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [passphrase, setPassphrase] = useState(null); // save-gate active while set
  const [password, setPassword] = useState('');

  const orgKey = domain.key;

  const reload = useCallback(async () => {
    try {
      const domains = (await api.listDomains(orgKey)).domains || [];
      const rec = domains.find((d) => d.name === domain.domain) || domains[0];
      setRecord(rec || null);
      if (rec) setStateData((await api.getDomainE2ee(orgKey, rec.id)).e2ee);
    } catch (e) {
      log.warn('E2EE', `state load failed: ${e?.message || e}`);
      setError("Couldn't load encryption state.");
    } finally {
      setLoading(false);
    }
  }, [orgKey, domain.domain]);

  useEffect(() => {
    let cancelled = false;
    // Defer past the initial synchronous render (lint: no sync setState in effects).
    Promise.resolve().then(() => { if (!cancelled) { refreshIdentity(); reload(); } });
    return () => { cancelled = true; };
  }, [reload]);

  const members = useMemo(() => stateData?.members || [], [stateData]);
  const membersWithKeys = useMemo(() => members.filter((m) => m.public_key), [members]);
  const membersWithoutKeys = useMemo(() => members.filter((m) => !m.public_key), [members]);

  const run = async (fn) => {
    setBusy(true); setError(null);
    try { await fn(); } catch (e) {
      log.warn('E2EE', e?.message || e);
      setError(e?.message || 'Something went wrong.');
    } finally { setBusy(false); }
  };

  // Step 1 — identity setup (generates the recovery passphrase → save-gate).
  const handleSetupIdentity = () => run(async () => {
    if (!password) throw new Error('Enter your account password first.');
    const { passphrase: phrase } = await setupIdentity(password);
    setPassword('');
    setPassphrase(phrase);
    await reload();
  });

  const handleUnlock = () => run(async () => {
    if (!password) throw new Error('Enter your account password first.');
    await unlock(password);
    setPassword('');
  });

  // Step 2 — mint the domain key and grant every member who has an identity.
  const handleMint = () => run(async () => {
    if (!isUnlocked()) throw new Error('Open your encryption key first.');
    await ready();
    const pair = generateDomainKey();
    const grants = membersWithKeys.map((m) => ({
      membership_id: m.membership_id,
      sealed_secret_key: sealGrant(pair.secretKey, m.public_key),
    }));
    await api.mintDomainKeys(orgKey, record.id, pair.publicKey, grants);
    await reload();
  });

  // Step 3 — the operational switch.
  const handleToggle = (enabled) => run(async () => {
    const res = await api.setDomainE2ee(orgKey, record.id, { e2ee_enabled: enabled });
    setRecord((r) => ({ ...r, e2ee_enabled: res.domain.e2ee_enabled }));
    await reload();
  });

  // Notification preview: opt-in rich push alerts for sealed mail at the cost
  // of leaking exactly sender + subject (docs/E2EE.md).
  const handlePreviewToggle = (on) => run(async () => {
    const res = await api.setDomainE2ee(orgKey, record.id, { e2ee_notification_preview: on });
    setRecord((r) => ({ ...r, e2ee_notification_preview: res.domain.e2ee_notification_preview }));
    await reload();
  });

  // Re-grant a member who now has an identity key but no grant yet.
  const handleGrant = (member) => run(async () => {
    if (!isUnlocked()) throw new Error('Open your encryption key first.');
    const secret = await loadDomainSecret(orgKey, record.id);
    if (!secret) throw new Error('You have no grant on the current key.');
    await ready();
    await api.grantDomainKey(orgKey, record.id, member.membership_id, sealGrant(secret.secretKey, member.public_key));
    await reload();
  });

  if (loading) {
    return <div className={styles.section}><Spinner size={20} color="var(--violet)" /></div>;
  }
  if (!record) {
    return <div className={styles.section}><p>No domain record found.</p></div>;
  }

  const entitled = stateData?.entitled;
  const hasKey = !!stateData?.current_key;
  const enabled = !!record.e2ee_enabled;

  return (
    <div className={styles.section}>
      <h2 className={styles.sectionTitle}>End-to-end encryption</h2>
      <p className={e2ee.lede}>
        Seal incoming mail for <strong>{record.name}</strong> so only your members can read it.
        Their keys never reach our servers.
      </p>

      {!entitled && (
        <div className={e2ee.notice}>
          <Icon name="lock.fill" size={14} />
          End-to-end encryption comes with paid plans. Upgrade to turn it on.
        </div>
      )}

      {entitled && (
        <>
          {/* Identity step */}
          <StepCard
            index={1}
            title="Your encryption identity"
            done={session.identityStatus === 'unlocked' || session.identityStatus === 'locked'}
          >
            {session.identityStatus === 'none' && (
              <>
                <p>
                  Create your personal key. Your password and a recovery passphrase protect it.{' '}
                  <strong>inbox2 can never read or reset it.</strong>
                </p>
                <PasswordRow
                  password={password} setPassword={setPassword} busy={busy}
                  action={handleSetupIdentity} label="Generate my key"
                />
              </>
            )}
            {session.identityStatus === 'locked' && (
              <>
                <p>Your key is set up. Open it to manage domain encryption.</p>
                <PasswordRow
                  password={password} setPassword={setPassword} busy={busy}
                  action={handleUnlock} label="Open"
                />
              </>
            )}
            {session.identityStatus === 'unlocked' && <p className={e2ee.ok}><Icon name="checkmark.circle.fill" size={13} /> Your key is open.</p>}
          </StepCard>

          {/* Domain key step */}
          <StepCard index={2} title="Domain sealing key" done={hasKey}>
            {hasKey ? (
              <p className={e2ee.ok}>
                <Icon name="checkmark.circle.fill" size={13} /> Key v{stateData.current_key.version} active.
                Inbound mail is sealed to this key{enabled ? '' : ' once encryption is switched on'}.
              </p>
            ) : (
              <>
                <p>
                  Create the domain key and give access to every member who has a key. You can add
                  the other {membersWithoutKeys.length} later.
                </p>
                <MgmtButton variant="primary" onClick={handleMint} disabled={busy || session.identityStatus !== 'unlocked'}>
                  {busy ? 'Working…' : 'Generate domain key'}
                </MgmtButton>
              </>
            )}
          </StepCard>

          {/* Switch */}
          <StepCard index={3} title="Seal inbound mail" done={enabled}>
            <p>
              {enabled
                ? 'We seal new mail for this domain the moment it arrives.'
                : 'Turn it on and we seal every new message for this domain.'}
            </p>
            <MgmtButton
              variant={enabled ? 'secondary' : 'primary'}
              onClick={() => handleToggle(!enabled)}
              disabled={busy || !hasKey}
            >
              {enabled ? 'Turn off sealing' : 'Turn on sealing'}
            </MgmtButton>
          </StepCard>

          {/* Notification preview trade-off */}
          {hasKey && (
            <div className={e2ee.step}>
              <div className={e2ee.stepHead}>
                <span className={e2ee.stepIndex}><Icon name="bell.fill" size={11} /></span>
                <span className={e2ee.stepTitle}>Notification previews</span>
              </div>
              <div className={e2ee.stepBody}>
                <p>
                  {record.e2ee_notification_preview
                    ? 'Push alerts show the sender and subject. Message bodies stay sealed.'
                    : 'Push alerts only say "New message". Nothing about sealed mail leaves the seal.'}
                </p>
                <label className={e2ee.previewToggle}>
                  <MgmtCheckbox
                    
                    checked={!!record.e2ee_notification_preview}
                    onChange={(ev) => handlePreviewToggle(ev.target.checked)}
                    disabled={busy}
                  />
                  <span>
                    Show sender &amp; subject in notifications
                    <em>Apple and Google see the sender and subject. Bodies stay sealed.</em>
                  </span>
                </label>
              </div>
            </div>
          )}

          {/* Members */}
          {hasKey && (
            <div className={e2ee.members}>
              <h3 className={e2ee.membersTitle}>Member access</h3>
              <ul className={e2ee.memberList}>
                {members.map((m) => (
                  <li key={m.membership_id} className={e2ee.memberRow}>
                    <span className={e2ee.memberName}>{m.display_name || m.membership_id}</span>
                    <span className={e2ee.memberRole}>{m.role}</span>
                    {m.has_grant ? (
                      <span className={e2ee.ok}><Icon name="checkmark.circle.fill" size={12} /> has access</span>
                    ) : m.public_key ? (
                      <MgmtButton variant="ghost" size="sm" onClick={() => handleGrant(m)} disabled={busy || session.identityStatus !== 'unlocked'}>
                        Grant access
                      </MgmtButton>
                    ) : (
                      <span className={e2ee.memberPending}>no identity key yet</span>
                    )}
                  </li>
                ))}
              </ul>
            </div>
          )}
        </>
      )}

      {error && (
        <p className={admin.settingsError} role="alert">
          <Icon name="exclamationmark.triangle.fill" size={13} /> {error}
        </p>
      )}

      {passphrase && (
        <RecoveryGate passphrase={passphrase} onDone={() => setPassphrase(null)} />
      )}
    </div>
  );
}

function StepCard({ index, title, done, children }) {
  return (
    <div className={e2ee.step} data-done={done ? 'true' : undefined}>
      <div className={e2ee.stepHead}>
        <span className={e2ee.stepIndex}>{done ? <Icon name="checkmark" size={11} /> : index}</span>
        <span className={e2ee.stepTitle}>{title}</span>
      </div>
      <div className={e2ee.stepBody}>{children}</div>
    </div>
  );
}

function PasswordRow({ password, setPassword, busy, action, label }) {
  return (
    <div className={e2ee.pwRow}>
      <input
        type="password"
        className={admin.modalInput}
        value={password}
        onChange={(e) => setPassword(e.target.value)}
        placeholder="Account password"
        aria-label="Account password"
        autoComplete="current-password"
        onKeyDown={(e) => { if (e.key === 'Enter') action(); }}
      />
      <MgmtButton variant="primary" onClick={action} disabled={busy || !password}>
        {busy ? 'Working…' : label}
      </MgmtButton>
    </div>
  );
}

// The HARD save-gate (docs/E2EE.md "Onboarding messaging"): the passphrase is
// shown exactly once, must be typed back to confirm it was saved, and the
// modal cannot be dismissed any other way. A copy of the recovery file is also
// emailed automatically (Option A).
export function RecoveryGate({ passphrase, onDone }) {
  const [typed, setTyped] = useState('');
  const matches = normalizePassphrase(typed) === normalizePassphrase(passphrase);

  return (
    <div className={e2ee.gateBackdrop} role="dialog" aria-modal="true" aria-label="Save your recovery passphrase">
      <div className={e2ee.gate}>
        <h3 className={e2ee.gateTitle}><Icon name="key.fill" size={16} /> Save your recovery passphrase</h3>
        <p className={e2ee.gateText}>
          You see this passphrase <strong>once</strong>. It recovers your key if you forget your
          password. <strong>inbox2 can’t recover it. Lose it and you may lose your sealed mail.</strong>{' '}
          Store it in a password manager now. We’ve emailed you a recovery file that only works
          with this passphrase.
        </p>
        <div className={e2ee.gatePhrase} aria-label="Recovery passphrase">{passphrase}</div>
        <label className={e2ee.gateConfirm}>
          <span>Type the passphrase to confirm you saved it:</span>
          <input
            className={admin.modalInput}
            value={typed}
            onChange={(e) => setTyped(e.target.value)}
            placeholder="word-word-word-word-word-word"
            autoComplete="off"
            spellCheck={false}
          />
        </label>
        <MgmtButton variant="primary" onClick={onDone} disabled={!matches}>
          I saved my passphrase
        </MgmtButton>
      </div>
    </div>
  );
}
