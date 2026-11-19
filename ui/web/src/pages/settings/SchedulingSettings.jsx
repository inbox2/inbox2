import { useState, useEffect, useCallback } from 'react';
import { useSearchParams } from 'react-router';
import api from '../../lib/api';
import { openLink } from '../../lib/openLink';
import { ACCOUNT_WEB_URL } from '../../lib/webOrigin';
import Button from '../../components/Button/Button';
import ConfirmDialog from '../../components/ConfirmDialog/ConfirmDialog';
import { MgmtSelect } from '../../components/management';
import log from '../../lib/log';
import AvailabilitySettings from './AvailabilitySettings';
import styles from './settings.module.css';

// Settings › Scheduling (docs/Calendar.md): per-member meet links — public
// busy/free pages that take meeting requests — plus the conferencing
// connections that let an accept generate a Meet/Teams link. Every member gets
// this (deliberately NOT a console page: links are personal, not admin).
const DURATIONS = [15, 30, 45, 60, 90, 120];
const NOTICE_OPTIONS = [
  { value: 0, label: 'No minimum notice' },
  { value: 60, label: '1 hour' },
  { value: 240, label: '4 hours' },
  { value: 1440, label: '24 hours' },
];
const AHEAD_OPTIONS = [
  { value: 7, label: '1 week ahead' },
  { value: 14, label: '2 weeks ahead' },
  { value: 28, label: '4 weeks ahead' },
  { value: 60, label: '2 months ahead' },
];
const PROVIDERS = [
  { key: 'google', label: 'Google', hint: 'Meet links', conference: 'meet' },
  { key: 'microsoft', label: 'Microsoft', hint: 'Teams links', conference: 'teams' },
];

const meetUrl = (token) => `${ACCOUNT_WEB_URL}/meet/${token}`;

function memberLabel(m) {
  return m.user?.display_name || m.user?.username || m.email_addresses?.[0] || 'member';
}

function LinkRow({ link, onRevoke, canRevoke }) {
  const [copied, setCopied] = useState(false);
  const copy = () => {
    navigator.clipboard?.writeText(meetUrl(link.token)).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    }).catch(() => {});
  };

  return (
    <div className={`${styles.schedLinkRow} ${link.active ? '' : styles.schedLinkRevoked}`}>
      <div className={styles.schedLinkName}>
        {link.label}
        <span className={styles.schedLinkMeta}>
          {link.duration_minutes} min
          {link.invitee && !link.invitee.self && ` · books ${link.invitee.name || 'a colleague'}`}
          {link.conference_mode === 'meet' && ' · Google Meet'}
          {link.conference_mode === 'teams' && ' · Teams'}
        </span>
      </div>
      {!link.active && <span className={styles.schedLinkMeta}>Revoked</span>}
      <span className={styles.schedLinkStats}>
        {link.visits_count} visits · {link.requests_count} requests
      </span>
      {link.active && canRevoke && (
        <Button variant="link" className={`${styles.schedRevoke} ${styles.schedRowBtn}`} onClick={() => onRevoke(link)}>Revoke</Button>
      )}
      {link.active && (
        <div className={styles.schedLinkUrlLine}>
          <code className={styles.schedLinkUrl} title={meetUrl(link.token)}>{meetUrl(link.token).replace(/^https?:\/\//, '')}</code>
          <Button variant="link" className={styles.schedRowBtn} onClick={copy}>{copied ? 'Copied' : 'Copy'}</Button>
          <Button variant="link" className={styles.schedRowBtn} onClick={() => openLink(meetUrl(link.token))}>Open</Button>
        </div>
      )}
    </div>
  );
}

export default function SchedulingSettings({ orgId }) {
  const [links, setLinks] = useState([]);
  const [bookingYou, setBookingYou] = useState([]);
  const [connections, setConnections] = useState([]);
  const [members, setMembers] = useState([]);
  const [error, setError] = useState(null);
  const [revoking, setRevoking] = useState(null);

  // Conferencing OAuth returns here with ?section=scheduling&conferencing=connected|error.
  const [searchParams] = useSearchParams();
  const oauthStatus = searchParams.get('conferencing');

  const [showForm, setShowForm] = useState(false);
  const [label, setLabel] = useState('');
  const [duration, setDuration] = useState(30);
  const [invitee, setInvitee] = useState('');
  const [conference, setConference] = useState('none');
  const [notice, setNotice] = useState(240);
  const [ahead, setAhead] = useState(28);
  const [saving, setSaving] = useState(false);

  const reload = useCallback(() => {
    if (!orgId) return;
    api.listMeetLinks(orgId)
      .then((res) => { setLinks(res?.meet_links || []); setBookingYou(res?.booking_you || []); })
      .catch((e) => setError(e?.message || "Couldn't load your links"));
    api.listConferencing(orgId)
      .then((res) => setConnections(res?.connections || []))
      .catch((e) => log.warn('Scheduling', `conferencing fetch failed: ${e?.message || e}`));
    api.getMembers(orgId)
      .then((res) => setMembers((res?.members || []).filter((m) => m.status === 'active')))
      .catch(() => setMembers([]));
  }, [orgId]);

  useEffect(reload, [reload]);

  const connectionFor = (provider) => connections.find((c) => c.provider === provider);

  const createLink = async (e) => {
    e.preventDefault();
    setSaving(true);
    setError(null);
    try {
      await api.createMeetLink(orgId, {
        label: label.trim(),
        duration_minutes: duration,
        invitee_membership_id: invitee || undefined,
        conference_mode: conference,
        min_notice_minutes: notice,
        max_ahead_days: ahead,
      });
      setLabel(''); setInvitee(''); setConference('none'); setShowForm(false);
      reload();
    } catch (err) {
      setError(err?.message || "Couldn't create the link");
    } finally {
      setSaving(false);
    }
  };

  const connect = async (provider) => {
    try {
      const res = await api.connectConferencing(orgId, provider);
      if (res?.authorize_url) openLink(res.authorize_url);
    } catch (e) {
      setError(e?.message || `Couldn't start the ${provider} connection`);
    }
  };

  const disconnect = async (provider) => {
    try {
      await api.disconnectConferencing(orgId, provider);
      reload();
    } catch (e) {
      setError(e?.message || "Couldn't disconnect");
    }
  };

  // The conference dropdown only offers what can actually generate a link.
  const conferenceChoices = [
    { value: 'none', label: 'No meeting link' },
    { value: 'meet', label: connectionFor('google') ? 'Google Meet, added when you accept' : 'Google Meet (connect Google below first)', disabled: !connectionFor('google') },
    { value: 'teams', label: connectionFor('microsoft') ? 'Teams, added when you accept' : 'Teams (connect Microsoft below first)', disabled: !connectionFor('microsoft') },
  ];

  // Two panels side by side on the wide settings column: your availability
  // (left) and the meet links + conferencing that publish it (right).
  return (
    <div className={styles.prefGrid}>
      <section className={styles.settingsPanel}>
        <AvailabilitySettings />
      </section>
      <section className={styles.settingsPanel}>
        <h1 className={styles.settingsTitle}>Scheduling</h1>
        <p className={styles.settingsIntro}>
          Share a meet link so anyone can request time with you. They only see when you’re free.
        </p>

        <div className={styles.schedHead}>
          <h2 className={styles.sectionTitle}>Meet links</h2>
          <Button variant="secondary" onClick={() => setShowForm(v => !v)}>
            {showForm ? 'Close' : '+ New link'}
          </Button>
        </div>

        {showForm && (
          <form className={styles.schedForm} onSubmit={createLink}>
            <div className={styles.schedFormGrid}>
              <div className={`${styles.settingsField} ${styles.schedFormWide}`}>
                <label htmlFor="meet-label">Label</label>
                <input id="meet-label" value={label} onChange={(e) => setLabel(e.target.value)} placeholder="e.g. Intro call" required />
              </div>
              <div className={styles.settingsField}>
                <label htmlFor="meet-duration">Duration</label>
                <MgmtSelect bare compact id="meet-duration" value={duration} onChange={(e) => setDuration(Number(e.target.value))}
                  options={DURATIONS.map((d) => ({ value: d, label: `${d} minutes` }))} />
              </div>
              <div className={styles.settingsField}>
                <label htmlFor="meet-invitee">Who gets booked</label>
                <MgmtSelect bare compact id="meet-invitee" value={invitee} onChange={(e) => setInvitee(e.target.value)}>
                  <option value="">You</option>
                  {members.map((m) => <option key={m.id} value={m.id}>{memberLabel(m)}</option>)}
                </MgmtSelect>
              </div>
              <div className={styles.settingsField}>
                <label htmlFor="meet-conference">Meeting link</label>
                <MgmtSelect bare compact id="meet-conference" value={conference} onChange={(e) => setConference(e.target.value)}>
                  {conferenceChoices.map((c) => (
                    <option key={c.value} value={c.value} disabled={c.disabled}>{c.label}</option>
                  ))}
                </MgmtSelect>
              </div>
              <div className={styles.settingsField}>
                <label htmlFor="meet-notice">Minimum notice</label>
                <MgmtSelect bare compact id="meet-notice" value={notice} onChange={(e) => setNotice(Number(e.target.value))} options={NOTICE_OPTIONS} />
              </div>
              <div className={styles.settingsField}>
                <label htmlFor="meet-ahead">Booking window</label>
                <MgmtSelect bare compact id="meet-ahead" value={ahead} onChange={(e) => setAhead(Number(e.target.value))} options={AHEAD_OPTIONS} />
              </div>
            </div>
            {invitee && (
              <p className={styles.schedFormNote}>
                The page shows this colleague&rsquo;s free time. They accept or decline each request.
              </p>
            )}
            <Button type="submit" className={styles.schedFormSubmit} disabled={saving || !label.trim()} aria-busy={saving}>Create link</Button>
          </form>
        )}

        {links.length === 0 && !showForm && (
          <p className={styles.schedEmpty}>No meet links yet.</p>
        )}
        {links.map((l) => <LinkRow key={l.id} link={l} canRevoke onRevoke={setRevoking} />)}

        {bookingYou.length > 0 && (
          <>
            <h2 className={`${styles.sectionTitle} ${styles.schedSectionTitle}`}>Links that book you</h2>
            <p className={styles.schedFormNote}>Colleagues made these. Requests land in your inbox, and you can revoke them.</p>
            {bookingYou.map((l) => <LinkRow key={l.id} link={l} canRevoke onRevoke={setRevoking} />)}
          </>
        )}

        <h2 className={`${styles.sectionTitle} ${styles.schedSectionTitle}`}>Conferencing</h2>
        {oauthStatus === 'connected' && <p className={styles.schedNotice}>Connected. Meeting links get added when you accept.</p>}
        {oauthStatus === 'error' && <p className={styles.settingsError}>The connection didn&rsquo;t complete. Try again.</p>}
        {PROVIDERS.map(({ key, label: pLabel, hint }) => {
          const conn = connectionFor(key);
          return (
            <div key={key} className={styles.schedLinkRow}>
              <div className={styles.schedLinkName}>
                {pLabel}
                <span className={styles.schedLinkMeta}>
                  {conn
                    ? `Connected${conn.account_email ? ` as ${conn.account_email}` : ''}. ${hint} get added when you accept`
                    : `Not connected. Connect to add ${hint}`}
                </span>
              </div>
              {conn
                ? <Button variant="link" className={`${styles.schedRevoke} ${styles.schedRowAction}`} onClick={() => disconnect(key)}>Disconnect</Button>
                : <Button variant="secondary" className={styles.schedRowAction} onClick={() => connect(key)}>Connect</Button>}
            </div>
          );
        })}

        {error && <p className={styles.settingsError}>{error}</p>}

        <ConfirmDialog
          open={!!revoking}
          title="Revoke this link?"
          message="The page stops working right away. Requests you already have stay."
          confirmLabel="Revoke"
          onCancel={() => setRevoking(null)}
          onConfirm={async () => {
            try {
              await api.revokeMeetLink(orgId, revoking.id);
              reload();
            } catch (e) {
              setError(e?.message || "Couldn't revoke");
            }
            setRevoking(null);
          }}
        />
      </section>
    </div>
  );
}
