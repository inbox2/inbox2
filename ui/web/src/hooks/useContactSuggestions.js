import { getDb } from '../lib/db.js';
import { DISCARDED_STATUSES, statusNotIn } from '../lib/conversationStatus.js';
import { useState, useEffect } from 'react';
import { isTauri } from '../lib/tauri';
import { parseAddressList } from '../lib/emailAddress';
import api from '../lib/api';
import { isRealOrgId } from '../lib/org';
import log from '../lib/log';

/**
 * Builds a deduplicated contact list for autocomplete.
 *
 * Desktop: queries SQLite conversations for all from/to addresses.
 * Web: queries the conversations API and extracts addresses.
 *
 * Returns: { contacts: Array<{ email, name, total }>, loading }
 */
export default function useContactSuggestions(orgSlug) {
  const [contacts, setContacts] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;

    async function load() {
      setLoading(true);
      const map = new Map();

      // Record one parsed { name, email } entry into the dedup map.
      function addEntry({ name, email }) {
        const e = (email || '').trim().toLowerCase();
        if (!e || !e.includes('@')) return;
        const nm = (name || '').trim();
        const existing = map.get(e);
        if (!existing) {
          map.set(e, { email: e, name: nm || e.split('@')[0], total: 1 });
        } else {
          existing.total++;
          // Upgrade to a richer (multi-word) name if we now have one.
          if (nm && nm.includes(' ') && !existing.name.includes(' ')) {
            existing.name = nm;
          }
        }
      }

      // Split a header value (single or comma/semicolon list) with the shared
      // RFC parser so quoted display names containing commas stay intact.
      function addAddresses(raw) {
        for (const entry of parseAddressList(raw)) addEntry(entry);
      }

      try {
        if (isTauri()) {
          const db = await getDb();
          const rows = await db.select(
            `SELECT from_address, to_address FROM conversations
             WHERE ${statusNotIn(DISCARDED_STATUSES)}`
          );
          for (const row of rows) {
            addAddresses(row.from_address);
            addAddresses(row.to_address); // may be a multi-recipient list
          }
        } else if (isRealOrgId(orgSlug)) {
          // Web: pull from conversations + members
          const [convData, memberData] = await Promise.all([
            api.get(`/orgs/${orgSlug}/conversations?per_page=100&page=1&include_sent=true`).catch(() => null),
            api.get(`/orgs/${orgSlug}/members`).catch(() => null),
          ]);

          // Extract addresses from conversations
          if (convData?.conversations) {
            for (const conv of convData.conversations) {
              addAddresses(conv.from_address);
              addAddresses(conv.to_address); // may be a multi-recipient list
            }
          }

          // Add org members (serialized as { user: { username, display_name } })
          if (memberData?.members) {
            for (const m of memberData.members) {
              const u = m.user || m;
              const username = u.username;
              const displayName = u.display_name || username;
              if (!username) continue;
              // Try billing_email first, otherwise use username as-is
              const email = u.billing_email || username;
              const key = email.toLowerCase();
              const existing = map.get(key);
              if (!existing) {
                map.set(key, { email: key, name: displayName, total: 500 });
              } else {
                existing.total += 500; // Boost members to top
                if (displayName && displayName.includes(' ')) existing.name = displayName;
              }
            }
          }
        }

        if (!cancelled) {
          const sorted = [...map.values()].sort((a, b) => b.total - a.total);
          setContacts(sorted);
          log.info('ContactSuggestions', `Loaded ${sorted.length} contacts`);
        }
      } catch (e) {
        log.warn('ContactSuggestions', `Failed to load: ${e?.message || e}`);
      } finally {
        if (!cancelled) setLoading(false);
      }
    }

    load();
    return () => { cancelled = true; };
  }, [orgSlug]);

  return { contacts, loading };
}
