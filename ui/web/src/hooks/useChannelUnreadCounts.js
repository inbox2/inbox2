import { getDb } from '../lib/db.js';
import { INBOX_HIDDEN_STATUSES, statusNotIn } from '../lib/conversationStatus.js';
import { FOLDER_ROLE } from '../lib/folderRoles.js';
import { useCallback, useEffect, useRef } from 'react';
import { isTauri } from '../lib/tauri';
import api from '../lib/localFirstApi';
import log from '../lib/log';
import useMailRefresh from './useMailRefresh';
import useRefetchOnFocus from './useRefetchOnFocus';
import useSyncRefresh from './useSyncRefresh';
import useUnreadStore from '../stores/unreadStore';

/**
 * THE writer of the unread badge. Every tab's count comes from here and from
 * nowhere else — `unreadStore.adjust` moves it optimistically between recounts
 * (see conversationActions.unreadDelta), and this hook is what makes it true.
 *
 * It used to have company: the unified inbox and the per-channel inbox each
 * counted unread rows in the list they happened to be holding and wrote that as
 * the channel's count. Those lists are paginated (25 from the API, 50 from the
 * local MX mirror, 200 from SQLite), so each screen had its own idea of the
 * number, an MX badge could never exceed 25, and the count changed as you
 * navigated. Both writers are gone; don't add a third.
 *
 * Local channels (Gmail/Office365/IMAP) are counted from SQLite in one grouped
 * query; org/MX channels from the API's exact count endpoint.
 */
export default function useChannelUnreadCounts(accounts) {
  const keysSig = (accounts || []).map(a => a.key).join(',');
  // Read through a ref so `refresh` stays stable — the subscriptions below must
  // not tear down and re-add on every render.
  const accountsRef = useRef(accounts);
  useEffect(() => { accountsRef.current = accounts; }, [accounts]);

  // Staleness guard. A recount reads asynchronously (SQLite query, HTTP), so its
  // answer describes the world as of when it STARTED. If the user files a thread
  // in that window, the in-flight read carries the pre-action count and would
  // overwrite the optimistic adjust with it — the badge then sat wrong until
  // something else recounted, which is most of what "the counter is stuck" was.
  // A recount may only write while it is still the newest one AND no local
  // mutation has landed since it started.
  const genRef = useRef(0);

  const refresh = useCallback(() => {
    const accounts = accountsRef.current || [];
    if (accounts.length === 0) return;

    const gen = ++genRef.current;
    const mutations = useUnreadStore.getState().mutations;
    const fresh = () => gen === genRef.current
      && useUnreadStore.getState().mutations === mutations;
    const setCount = (key, n) => {
      if (fresh()) useUnreadStore.getState().setChannelCount(key, n);
    };

    (async () => {
      const externals = accounts.filter(a => a.provider_type !== 'inbox2');
      const orgs = accounts.filter(a => a.provider_type === 'inbox2');

      // Local channels — one grouped query over the offline SQLite store. MUST
      // match what the inbox shows (useUnifiedInbox), so it uses the same
      // provider-INBOX join — a bare status filter also counts open+unread threads
      // that aren't in the provider inbox (sent replies, server-side moved/archived,
      // Meta channels in their own sub-views), inflating the badge vs the inbox.
      if (isTauri() && externals.length > 0) {
        try {
          const db = await getDb();
          // Drive from unread conversations (a tiny, indexed set) and test inbox
          // membership with EXISTS — NOT a JOIN through message_provider_state.
          // The join form forced a full SCAN of message_provider_state (one row
          // per message-per-folder, which archive/All-Mail sync grew to tens of
          // thousands), costing ~2.5s cold on every recompute regardless of how
          // few threads are unread. EXISTS short-circuits at the first inbox
          // message, so the cost scales with unread count, not mailbox size.
          //
          // Inbox membership is an mps row in the account's INBOX folder, and
          // ONLY that. Do not re-add a `mps.labels LIKE '%"INBOX"%'` fallback:
          // the labels column is a per-folder snapshot taken when that row was
          // last written, and an All Mail row is not rewritten when the message
          // leaves the inbox. Two threads read in Gmail on 2026-08-07 still
          // carried `["UNREAD","INBOX"]` (and `read:false, archived:false`) on
          // their All Mail row twelve days later, so the fallback counted 2
          // unread that the inbox list — which tests folder_key — correctly
          // showed as none. Clicking the tab wrote 0 over the badge and the next
          // recount put 2 back, forever.
          const rows = await db.select(
            `SELECT c.organization_id AS acct, COUNT(*) AS n
             FROM conversations c
             WHERE c.read = 0 AND ${statusNotIn(INBOX_HIDDEN_STATUSES, 'c.status')}
               AND EXISTS (
                 SELECT 1 FROM messages m
                 JOIN message_provider_state mps ON mps.message_key = m.key
                 JOIN external_folders ef ON ef.key = mps.folder_key
                 WHERE m.conversation_key = c.key
                   AND mps.account_key = c.organization_id
                   AND ef.well_known_role = '${FOLDER_ROLE.INBOX}'
               )
             GROUP BY c.organization_id`
          );
          const byAcct = Object.fromEntries(rows.map(r => [r.acct, r.n]));
          for (const a of externals) setCount(a.key, byAcct[a.key] || 0);
        } catch (e) {
          log.warn('Unread', `SQLite count failed: ${e?.message || e}`);
        }
      }

      // Org/MX channels — the API counts the open pool server-side. A per-domain
      // tab (from useAccounts) is keyed by the domain's dom_ id, which is NOT an
      // org identifier: address the org (by its slug) and narrow with ?domain=,
      // the same axis the inbox list uses. The unified view's per-org account
      // (from useUnifiedInbox) is keyed by the org slug and carries no domainKey,
      // so it counts the whole org pool. Either way the badge stays keyed by a.key.
      await Promise.all(orgs.map(async (a) => {
        try {
          const isDomain = a.domainKey?.startsWith('dom_');
          const orgId = isDomain ? (a.orgSlug || a.key) : a.key;
          const data = await api.getUnreadCount(orgId, isDomain ? { domain: a.domainKey } : {});
          setCount(a.key, data.unread_count || 0);
        } catch (e) {
          log.warn('Unread', `Count fetch failed for ${a.key}: ${e?.message || e}`);
        }
      }));
    })();
  }, []);

  // Recount when the tab set changes (a just-added channel's badge must not stay
  // empty until it's visited, and none show right after a reload).
  // ponytail: ChromeBar remounts on every navigation, so this also recounts once
  // per tab switch — a COUNT query and one small request per MX tab. Add a
  // shared "not again within Ns" timestamp only if that ever shows up as noise.
  //
  // A CHANGED set (not the first one this mount saw) also prunes: this hook is
  // the only writer, so anything left over is a removed account, and its count
  // would otherwise keep inflating the summed total behind the dock badge. Not
  // on the first run — MX tabs come from the auth context synchronously while
  // external channels arrive a tick later, so a fresh mount's first set is
  // partial and pruning on it would blank every channel badge on navigation.
  const seenSetRef = useRef(false);
  useEffect(() => {
    if (seenSetRef.current) {
      useUnreadStore.getState().pruneTo((accountsRef.current || []).map(a => a.key));
    }
    seenSetRef.current = true;
    refresh();
  }, [keysSig, refresh]); // refresh is stable (no deps) — keysSig is what fires this

  // Recount on exactly the events that change what the inbox lists show, so the
  // badge and the list can't drift: sync data changes, new MX mail over
  // ActionCable, and window focus. Running only on mount used to freeze a
  // background channel's badge at its startup value for hours.
  //
  // Slower than the lists on purpose: a badge may lag a beat, and an initial
  // sync fires data-change events continuously — at the list's 1.5s throttle
  // that would be a recount (a query per channel + a request per MX tab) every
  // 1.5s for the length of the sync. The optimistic adjust covers the user's own
  // actions in between, so only mail arriving elsewhere waits on this.
  useSyncRefresh(refresh, { throttleMs: 5000, failsafeMs: 60000 });
  useMailRefresh(refresh);
  useRefetchOnFocus(refresh);
}
