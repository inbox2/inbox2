import { getDb } from '../lib/db.js';
import { DISCARDED_STATUSES, statusNotIn } from '../lib/conversationStatus.js';
import { useState, useEffect, useRef } from 'react';
import { emailOnly, displayName, parseAddressList } from '../lib/emailAddress';
import { isTauri } from '../lib/tauri';
import { scrubIfDemo } from '../lib/demoData';
import api from '../lib/api';
import log from '../lib/log';
import { providerIcon } from '../lib/providerTypes';
import { mergeEntityGraphs } from '../lib/entityGraph';

/**
 * Build graph nodes + links from local SQLite conversation rows.
 * Shared by both unified-mode (per-account) and single-account code paths.
 */
function buildLocalGraph(rows) {
  const mailboxMap = new Map();
  const contactMap = new Map();
  const linkMap = new Map();

  // ISO timestamps compare lexicographically — cheap window boundaries
  const DAY = 24 * 3600 * 1000;
  const dayAgo = new Date(Date.now() - DAY).toISOString();
  const weekAgo = new Date(Date.now() - 7 * DAY).toISOString();
  const twoWeeksAgo = new Date(Date.now() - 14 * DAY).toISOString();
  const todayStart = new Date(new Date().setHours(0, 0, 0, 0)).toISOString();
  const localStats = { inbound_today: 0, recent7: 0, prior7: 0 };

  for (const row of rows) {
    // Split to_address into individual recipients (handles CC lists)
    const toAddresses = parseAddressList(row.to_address).filter(a => a.email);
    const fromEmail = emailOnly(row.from_address).toLowerCase();
    // Someone is waiting on a reply: the latest non-draft message is inbound
    const isWaiting = row.last_inbound === 1 && row.last_at;

    if (row.created_at >= todayStart) localStats.inbound_today++;
    if (row.created_at >= weekAgo) localStats.recent7++;
    else if (row.created_at >= twoWeeksAgo) localStats.prior7++;

    for (const { email: rawEmail, name: parsedName } of toAddresses) {
      const toEmail = rawEmail.toLowerCase();
      const e = mailboxMap.get(toEmail) || {
        name: parsedName || displayName(toEmail), total: 0, unread: 0,
        recent: 0, prior: 0, today: 0, waiting: 0, waiting24: 0, oldestWaiting: null,
      };
      // Upgrade name if we now have a richer display name (contains a space)
      if (parsedName && parsedName.includes(' ') && !e.name.includes(' ')) e.name = parsedName;
      e.total++;
      if (!row.read) e.unread++;
      if (row.created_at >= todayStart) e.today++;
      if (row.created_at >= weekAgo) e.recent++;
      else if (row.created_at >= twoWeeksAgo) e.prior++;
      if (isWaiting) {
        e.waiting++;
        if (row.last_at < dayAgo) e.waiting24++;
        if (!e.oldestWaiting || row.last_at < e.oldestWaiting) e.oldestWaiting = row.last_at;
      }
      mailboxMap.set(toEmail, e);

      if (fromEmail) {
        const key = `${fromEmail}→${toEmail}`;
        linkMap.set(key, (linkMap.get(key) || 0) + 1);
      }
    }

    if (fromEmail) {
      const fromName = displayName(row.from_address);
      const e = contactMap.get(fromEmail) || { name: fromName, total: 0, unread: 0 };
      if (fromName && fromName.includes(' ') && !e.name.includes(' ')) e.name = fromName;
      e.total++;
      if (!row.read) e.unread++;
      contactMap.set(fromEmail, e);
    }
  }

  // Top 100 mailbox nodes by unread then total
  const mailboxEntries = [...mailboxMap.entries()]
    .sort((a, b) => b[1].unread - a[1].unread || b[1].total - a[1].total)
    .slice(0, 100);
  const mailboxAddrs = new Set(mailboxEntries.map(([e]) => e));

  // Top 150 contact nodes (excluding mailboxes, min 2 messages)
  const contactEntries = [...contactMap.entries()]
    .filter(([e]) => !mailboxAddrs.has(e))
    .filter(([, d]) => d.total >= 2)
    .sort((a, b) => b[1].total - a[1].total)
    .slice(0, 150);

  const nodes = { mailboxEntries, contactEntries, mailboxAddrs };

  // Links (top 500, both endpoints must be known nodes)
  const allAddrs = new Set([...mailboxEntries.map(([e]) => e), ...contactEntries.map(([e]) => e)]);
  const links = [...linkMap.entries()]
    .filter(([k]) => { const [s, t] = k.split('→'); return allAddrs.has(s) && allAddrs.has(t); })
    .sort((a, b) => b[1] - a[1])
    .slice(0, 500)
    .map(([key, weight]) => {
      const [source, target] = key.split('→');
      return { source, target, weight, kind: 'inbound' };
    });

  return { nodes, links, localStats };
}

// Mirror of the backend urgency weighting: unread ratio + how long the oldest
// unanswered inbound conversation has been waiting (saturates at 72h).
function computeUrgency(total, unread, oldestWaitingAt) {
  if (!total) return 0;
  const waitHours = oldestWaitingAt ? (Date.now() - new Date(oldestWaitingAt).getTime()) / 3600000 : 0;
  return 0.5 * (unread / total) + 0.5 * Math.min(waitHours / 72, 1);
}

function toGraphNode(email, d, type) {
  return {
    id: email,
    address: email,
    name: d.name,
    type,
    total: d.total,
    unread: d.unread,
    recent: d.recent || 0,
    prior: d.prior || 0,
    today: d.today || 0,
    waiting: d.waiting || 0,
    waiting_over_24h: d.waiting24 || 0,
    oldest_waiting_at: d.oldestWaiting || null,
    urgency: computeUrgency(d.total, d.unread, d.oldestWaiting),
  };
}

// Org-level KPI block derived from a set of graph nodes + per-source totals —
// the local/unified equivalent of the backend snapshot's `stats`.
function statsFromNodes(nodes, totals) {
  const mailboxes = nodes.filter(n => n.type === 'mailbox');
  if (mailboxes.length === 0 && !totals.recent7 && !totals.inbound_today) return null;
  const busiest = mailboxes.reduce((best, n) =>
    (!best || (n.recent || 0) > (best.recent || 0) ||
      ((n.recent || 0) === (best.recent || 0) && n.total > best.total)) ? n : best, null);
  const oldest = mailboxes.filter(n => n.oldest_waiting_at).map(n => n.oldest_waiting_at).sort()[0] || null;
  return {
    inbound_today: totals.inbound_today || 0,
    recent7: totals.recent7 || 0,
    prior7: totals.prior7 || 0,
    waiting: mailboxes.reduce((s, n) => s + (n.waiting || 0), 0),
    waiting_over_24h: mailboxes.reduce((s, n) => s + (n.waiting_over_24h || 0), 0),
    oldest_waiting_at: oldest,
    busiest: busiest && { address: busiest.address, recent: busiest.recent || 0, total: busiest.total },
    top_external_domain: totals.top_external_domain || null,
  };
}

async function fetchLocalRows(orgId) {
  const db = await getDb();
  // The Explorer is an email/contact network keyed on email addresses. Meta
  // channels (Instagram/Messenger/WhatsApp) thread on PSIDs/wa_ids/usernames,
  // not emails, so they'd render as garbled email-less nodes — exclude them
  // (`channel IS NULL` = email). A dedicated Meta social graph is a future feature.
  //
  // last_at/last_inbound (latest non-draft message) drive the "waiting on a
  // reply" analytics. ponytail: two correlated subselects per row — fine at
  // local-mailbox scale via idx_messages_conv.
  return db.select(
    `SELECT from_address, to_address, read, created_at,
       (SELECT m.created_at FROM messages m WHERE m.conversation_key = conversations.key AND m.is_draft = 0
        ORDER BY m.created_at DESC LIMIT 1) AS last_at,
       (SELECT m.is_inbound FROM messages m WHERE m.conversation_key = conversations.key AND m.is_draft = 0
        ORDER BY m.created_at DESC LIMIT 1) AS last_inbound
     FROM conversations
     WHERE organization_id = ?1 AND channel IS NULL AND ${statusNotIn(DISCARDED_STATUSES)}`,
    [orgId]
  );
}

// ─── Unified mode: merge graph data from ALL accounts ───────────────

async function buildUnifiedGraph(accountList, hubImageCache) {
  const hubNodes = [];
  const hubEmails = new Set();
  const hubEmailToId = new Map();

  for (const acct of accountList) {
    hubNodes.push({
      id: `hub::${acct.key}`,
      address: acct.email_address || acct.display_name,
      name: acct.display_name,
      type: 'channel_hub',
      total: 0,
      unread: 0,
      urgency: 0,
      providerType: acct.provider_type,
    });

    // Preload provider icon
    if (!hubImageCache.current[acct.provider_type]) {
      const img = new Image();
      img.src = providerIcon(acct.provider_type);
      hubImageCache.current[acct.provider_type] = img;
    }

    const email = (acct.email_address || '').toLowerCase().trim();
    if (email) {
      hubEmails.add(email);
      hubEmailToId.set(email, `hub::${acct.key}`);
    }
  }

  // Phase 1: Collect per-account nodes + links
  const mergedNodes = new Map();
  const rawLinks = [];
  // Accumulated org-level totals across all sources (MX stats + local rows)
  const totals = { inbound_today: 0, recent7: 0, prior7: 0, top_external_domain: null };

  const mergeNode = (email, name, type, m, acctKey) => {
    if (hubEmails.has(email)) return; // self node → represented by hub
    const existing = mergedNodes.get(email);
    if (existing) {
      existing.total += m.total || 0;
      existing.unread += m.unread || 0;
      existing.recent += m.recent || 0;
      existing.prior += m.prior || 0;
      existing.today += m.today || 0;
      existing.waiting += m.waiting || 0;
      existing.waiting24 += m.waiting24 || 0;
      if (m.oldestWaiting && (!existing.oldestWaiting || m.oldestWaiting < existing.oldestWaiting)) {
        existing.oldestWaiting = m.oldestWaiting;
      }
      if (type === 'mailbox') existing.type = 'mailbox';
      existing.accountKeys.add(acctKey);
    } else {
      mergedNodes.set(email, {
        name, type,
        total: m.total || 0, unread: m.unread || 0,
        recent: m.recent || 0, prior: m.prior || 0, today: m.today || 0,
        waiting: m.waiting || 0, waiting24: m.waiting24 || 0,
        oldestWaiting: m.oldestWaiting || null,
        accountKeys: new Set([acctKey]),
      });
    }
  };

  const mergeTotals = (s) => {
    if (!s) return;
    totals.inbound_today += s.inbound_today || 0;
    totals.recent7 += s.recent7 || 0;
    totals.prior7 += s.prior7 || 0;
    if (s.top_external_domain &&
        (!totals.top_external_domain || s.top_external_domain.recent > totals.top_external_domain.recent)) {
      totals.top_external_domain = s.top_external_domain;
    }
  };

  // MX mailbox stats are ORG-level. A per-domain tab's key is a dom_ id (NOT an
  // org id → 404), and every domain of an org returns the same org-wide graph, so
  // fetch each org once by its slug. Nodes are tagged with the account's own key
  // (a real workspace) so a node click still resolves to an inbox.
  const seenOrgs = new Set();
  for (const acct of accountList) {
    if (acct.provider_type === 'inbox2') {
      const orgKey = acct.orgSlug || acct.key;
      if (seenOrgs.has(orgKey)) continue;
      seenOrgs.add(orgKey);
      try {
        const data = await api.getMailboxStats(orgKey);
        mergeTotals(data.stats);
        for (const n of data.nodes || []) {
          mergeNode(n.address || n.id, n.name, n.type, {
            total: n.total, unread: n.unread, recent: n.recent, prior: n.prior, today: n.today,
            waiting: n.waiting, waiting24: n.waiting_over_24h, oldestWaiting: n.oldest_waiting_at,
          }, acct.key);
        }
        for (const l of data.links || []) {
          const sAddr = (data.nodes || []).find(n => n.id === l.source)?.address || l.source;
          const tAddr = (data.nodes || []).find(n => n.id === l.target)?.address || l.target;
          rawLinks.push({ source: sAddr, target: tAddr, weight: l.weight || 1, kind: l.kind || 'inbound' });
        }
      } catch (e) {
        log.warn('Explorer', `Unified: failed to fetch org ${orgKey}: ${e?.message}`);
      }
    } else if (isTauri()) {
      try {
        const rows = await fetchLocalRows(acct.key);
        const { nodes: local, links: localLinks, localStats } = buildLocalGraph(rows);
        mergeTotals(localStats);
        for (const [email, d] of local.mailboxEntries) mergeNode(email, d.name, 'mailbox', d, acct.key);
        for (const [email, d] of local.contactEntries) mergeNode(email, d.name, 'contact', d, acct.key);
        rawLinks.push(...localLinks);
      } catch (e) {
        log.warn('Explorer', `Unified: failed to build graph for ${acct.key}: ${e?.message}`);
      }
    }
  }

  // Phase 2: Build final nodes
  const allNodes = [...hubNodes];
  for (const [email, d] of mergedNodes) {
    allNodes.push({
      ...toGraphNode(email, d, d.type),
      accountKeys: [...d.accountKeys],
    });
  }

  // Phase 3: Build final links (remap hub emails → hub node IDs)
  const nodeIds = new Set(allNodes.map(n => n.id));
  const linkDedup = new Map();
  for (const l of rawLinks) {
    const source = hubEmailToId.get(l.source) || l.source;
    const target = hubEmailToId.get(l.target) || l.target;
    if (!nodeIds.has(source) || !nodeIds.has(target)) continue;
    if (source === target) continue;
    const key = `${source}→${target}`;
    const existing = linkDedup.get(key);
    if (existing) {
      existing.weight += l.weight;
    } else {
      linkDedup.set(key, { ...l, source, target });
    }
  }
  const allLinks = [...linkDedup.values()];

  // Hub links — each merged node connects to every hub it belongs to
  for (const [email, d] of mergedNodes) {
    for (const acctKey of d.accountKeys) {
      allLinks.push({ source: `hub::${acctKey}`, target: email, weight: d.total, kind: 'internal' });
    }
  }

  // Update hub totals
  for (const hub of hubNodes) {
    const acctKey = hub.id.replace('hub::', '');
    let total = 0, unread = 0;
    for (const [, d] of mergedNodes) {
      if (d.accountKeys.has(acctKey)) { total += d.total; unread += d.unread; }
    }
    hub.total = total;
    hub.unread = unread;
  }

  return { nodes: allNodes, links: allLinks, stats: statsFromNodes(allNodes, totals) };
}

// ─── Single-account mode: local SQLite or API ───────────────────────

async function buildSingleGraph(orgId, isLocal) {
  if (isLocal) {
    const rows = await fetchLocalRows(orgId);
    const { nodes: local, links, localStats } = buildLocalGraph(rows);
    const nodes = [
      ...local.mailboxEntries.map(([email, d]) => toGraphNode(email, d, 'mailbox')),
      ...local.contactEntries.map(([email, d]) => toGraphNode(email, d, 'contact')),
    ];
    return { nodes, links, stats: statsFromNodes(nodes, localStats) };
  }

  // API org
  const data = await api.getMailboxStats(orgId);
  return {
    nodes: (data.nodes || []).map(n => ({ ...n })),
    links: (data.links || []).map(l => ({ ...l })),
    stats: data.stats && Object.keys(data.stats).length > 0 ? data.stats : null,
  };
}

// ─── Hook ───────────────────────────────────────────────────────────

/**
 * Manages Explorer graph data loading for both unified and single-account modes.
 *
 * @param {Object} params
 * @param {string} params.orgId - Current org or account ID
 * @param {boolean} params.isLocalAccount - Whether viewing a local (Tauri) account
 * @param {boolean} params.unifiedMode - Whether unified (all-accounts) mode is active
 * @param {Array} params.allAccounts - All accounts (org + external)
 * @returns {{ graphData, loading, hubImageCache }}
 */
export default function useExplorerGraph({ orgId, isLocalAccount, unifiedMode, allAccounts }) {
  const [graphData, setGraphData] = useState({ nodes: [], links: [] });
  const [stats, setStats] = useState(null);
  const [loading, setLoading] = useState(true);
  const hubImageCache = useRef({});

  // Unified mode
  useEffect(() => {
    if (!unifiedMode) return;
    let cancelled = false;

    (async () => {
      try {
        const result = await buildUnifiedGraph(allAccounts || [], hubImageCache);
        if (!cancelled) {
          setGraphData({ nodes: result.nodes, links: result.links });
          setStats(result.stats || null);
          setLoading(false);
        }
      } catch (e) {
        log.error('Explorer', `Unified graph failed: ${e?.message || e}`);
        if (!cancelled) { setGraphData({ nodes: [], links: [] }); setLoading(false); }
      }
    })();

    return () => { cancelled = true; };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [unifiedMode, allAccounts.length]);

  // Single-account mode
  useEffect(() => {
    if (!orgId || unifiedMode) return;
    let cancelled = false;

    (async () => {
      try {
        const result = await buildSingleGraph(orgId, isLocalAccount);
        if (!cancelled) {
          setGraphData({ nodes: result.nodes, links: result.links });
          setStats(result.stats || null);
        }
      } catch (e) {
        log.warn('Explorer', `Failed to build graph: ${e?.message || e}`);
        if (!cancelled) { setGraphData({ nodes: [], links: [] }); setStats(null); }
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();

    return () => { cancelled = true; };
  }, [orgId, isLocalAccount, unifiedMode]);

  return { graphData, stats, loading, hubImageCache };
}

// ─── Entity graph (Lore ontology, docs/Ontology.md) ─────────────────

/**
 * The Explorer's default view: organizations, people, products and projects
 * mined from mail. MX: one `GET /orgs/:id/lore/graph` per org (each org once,
 * by slug, as the mailbox graph does). Desktop: the local channels'
 * `lore_graph` command. Merged by lib/entityGraph.
 */
export function useEntityGraph({ allAccounts, enabled }) {
  const [state, setState] = useState({ graphData: { nodes: [], links: [] }, loading: true });
  const orgKeys = [...new Set((allAccounts || [])
    .filter(a => a.provider_type === 'inbox2')
    .map(a => a.orgSlug || a.key))].join(',');

  useEffect(() => {
    if (!enabled) return undefined;
    let cancelled = false;
    (async () => {
      const sources = orgKeys ? orgKeys.split(',').map(key => api.getLoreGraph(key).catch((e) => {
        log.warn('Explorer', `Lore graph for ${key} failed: ${e?.message}`);
        return null;
      })) : [];
      if (isTauri()) {
        sources.push(import('@tauri-apps/api/core')
          // Engine reads bypass lib/db's demo scrub (lib/demoData.js).
          .then(({ invoke }) => invoke('lore_graph').then(scrubIfDemo))
          .catch((e) => { log.warn('Explorer', `Local lore graph failed: ${e?.message || e}`); return null; }));
      }
      const graphs = await Promise.all(sources);
      if (!cancelled) setState({ graphData: mergeEntityGraphs(graphs), loading: false });
    })();
    return () => { cancelled = true; };
  }, [enabled, orgKeys]);

  return state;
}
