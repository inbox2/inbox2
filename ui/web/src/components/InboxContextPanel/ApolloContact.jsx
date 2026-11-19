import { useEffect, useMemo, useState } from 'react';
import { parseAddressList } from '../../lib/emailAddress';
import { enrichContact, getCachedContact, isApolloConfigured } from '../../lib/apollo-enrichment';
import Avatar from '../Avatar';
import Icon from '../Icon';
import ApolloLogo from '../ApolloLogo';
import DropdownMenu from '../DropdownMenu/DropdownMenu';
import { ContextField, ContextRow } from '../ContextPanel';
import AddressContextMenu from '../DropdownMenu/AddressContextMenu';
import layout from '../../styles/layout.module.css';
import styles from './ApolloContact.module.css';

const cleanLinkedIn = (url) =>
  url.replace('http://www.linkedin.com/in/', '').replace('https://www.linkedin.com/in/', '');

// Collect every distinct participant across the conversation (sender, recipients,
// cc on each message) so the user can enrich whichever person they care about —
// not just the thread's from_address.
function deriveParticipants(conversation) {
  const map = new Map();
  const add = (raw) => {
    for (const a of parseAddressList(raw)) {
      const key = a.email.toLowerCase();
      if (key && !map.has(key)) map.set(key, a);
    }
  };
  add(conversation.from_address);
  add(conversation.to_address);
  for (const m of conversation.messages || []) {
    add(m.from_address);
    add(m.to_address);
    add(m.cc_address);
  }
  return [...map.values()];
}

export default function ApolloContact({ conversation }) {
  const participants = useMemo(() => deriveParticipants(conversation), [conversation]);
  const defaultEmail = participants[0]?.email || '';

  const [configured, setConfigured] = useState(false);
  const [selected, setSelected] = useState(defaultEmail);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);
  // Results fetched (or confirmed via the button) this session, keyed by email.
  // Lets a fresh fetch re-render without a separate cache read.
  const [loaded, setLoaded] = useState({});

  useEffect(() => { isApolloConfigured().then(setConfigured); }, []);

  // Reset the picker to the new thread's primary participant when the
  // conversation changes — done during render (React's recommended pattern)
  // rather than in an effect, to avoid a cascading re-render.
  const [prevDefault, setPrevDefault] = useState(defaultEmail);
  if (prevDefault !== defaultEmail) {
    setPrevDefault(defaultEmail);
    setSelected(defaultEmail);
    setError(null);
  }

  const selectedParticipant =
    participants.find(p => p.email.toLowerCase() === selected.toLowerCase()) || participants[0];

  const cached = getCachedContact(selected);
  const resolved = (selected in loaded) || cached.hit;
  const data = (selected in loaded) ? loaded[selected] : cached.data;

  async function load() {
    if (!selected || loading) return;
    setLoading(true);
    setError(null);
    try {
      const result = await enrichContact(selected); // writes through the shared cache
      setLoaded(prev => ({ ...prev, [selected]: result }));
    } catch (err) {
      // Hard failure (auth / rate-limit / CORS) — distinct from a real no-match.
      setError(err.message || 'Couldn’t reach Apollo.');
    } finally {
      setLoading(false);
    }
  }

  if (!selectedParticipant) return null;

  const name = data?.name || selectedParticipant.name;
  const email = selectedParticipant.email;
  const domain = email.split('@')[1];

  const participantItems = participants.map(p => ({
    label: p.name ? `${p.name} · ${p.email}` : p.email,
    value: p.email,
    onSelect: () => { setSelected(p.email); setError(null); },
  }));

  return (
    <>
      <ContextRow>
        <Avatar name={name} email={email} size={28} src={data?.photo_url} />
        <div className={styles.identity}>
          <ContextField label=""><span className={layout.contextValueBold}>{name}</span></ContextField>
          <ContextField label="" mono><AddressContextMenu focusable email={email} name={data?.name || (selectedParticipant.explicit ? selectedParticipant.name : '')}>{email}</AddressContextMenu></ContextField>
        </div>
      </ContextRow>

      {participants.length > 1 && (
        <ContextField label="Person">
          <DropdownMenu
            align="left"
            value={selected}
            items={participantItems}
            trigger={
              <button type="button" className={styles.picker}>
                <Icon name="person.fill" size={11} />
                <span className={styles.pickerLabel}>{selectedParticipant.name || email}</span>
                <Icon name="chevron.down" size={8} />
              </button>
            }
          />
        </ContextField>
      )}

      {data?.title && <ContextField label="Title">{data.title}</ContextField>}
      {data?.company && <ContextField label="Company">{data.company}</ContextField>}
      {data?.linkedin_url && (
        <ContextField label="LinkedIn">
          <a href={data.linkedin_url} target="_blank" rel="noopener noreferrer" className={layout.contextLink}>
            {cleanLinkedIn(data.linkedin_url)}
          </a>
        </ContextField>
      )}
      {data?.city && (
        <ContextField label="Location">
          {[data.city, data.state, data.country].filter(Boolean).join(', ')}
        </ContextField>
      )}

      <ContextField label="Domain">{domain}</ContextField>
      <ContextField label="History">{conversation.messages?.length || 0} messages</ContextField>

      {configured && (
        <div className={styles.apolloFooter}>
          <button type="button" className={styles.loadButton} onClick={load} disabled={loading}>
            {loading
              ? <Icon name="arrow.triangle.2.circlepath" size={12} />
              : <ApolloLogo size={13} />}
            {loading ? 'Enriching…' : resolved ? 'Re-enrich' : 'Enrich'}
          </button>
          {error && <span className={styles.apolloError} title={error}>{error}</span>}
          {!error && resolved && !data && <span className={styles.apolloNote}>No match</span>}
          {!error && resolved && data && (
            <span className={styles.apolloNote}>
              <Icon name="checkmark.circle.fill" size={10} /> enriched
            </span>
          )}
        </div>
      )}
    </>
  );
}
