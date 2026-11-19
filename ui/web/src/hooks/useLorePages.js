import { useCallback, useEffect, useState } from 'react';
import diskApi from '../lib/disk/api';
import log from '../lib/log';
import { isRealOrgId } from '../lib/org';
import useAuth from './useAuth';
import { isDemoMode } from '../lib/demoData';

/*
 * The person's own Lore pages: Disk pages in a "Lore" folder on C:\ (their own
 * disk, the same from every team — docs/plans/disk.md). Notes therefore get
 * Disk's editor, history, search and MCP for free, and Lore stores nothing new.
 *
 *   useLorePages() → { orgId, pages, notesId, loading, error, createPage, reload }
 *     notesId — the "Lore notes" page under the Today view, made on first use
 */
export const LORE_FOLDER = 'Lore';
export const NOTES_PAGE = 'Lore notes';
export const DEMO_NOTES_ID = 'demo-notes';
const DEMO_PAGES = [
  { id: 'demo-launch', name: 'Q4 launch checklist', kind: 'page' },
  { id: 'demo-hiring', name: 'Hiring plan', kind: 'page' },
];

// Every child of a folder: the listing is cursor-paged.
async function allChildren(orgId, parentId, params) {
  const out = [];
  let cursor;
  do {
    const page = await diskApi.children(orgId, parentId, params, cursor);
    out.push(...(page.nodes || []));
    cursor = page.next_cursor || null;
  } while (cursor);
  return out;
}

async function childNamed(orgId, parentId, name, kind) {
  const nodes = await allChildren(orgId, parentId, { sort: 'name', dir: 'asc' });
  return nodes.find((n) => n.name === name && (n.kind || 'folder') === kind) || null;
}

const DISK_ACTIVE = 'active';

/** The first org whose Disk is reachable and writable, with its drives payload. */
async function writableDiskOrg(ids) {
  for (const id of ids) {
    try {
      const drives = await diskApi.drives(id);
      if ((drives.settings?.state || DISK_ACTIVE) === DISK_ACTIVE) return { id, drives };
    } catch { /* this team has no Disk — try the next */ }
  }
  return null;
}

async function ensureFolder(orgId, drives) {
  const { c_drive: root } = drives || await diskApi.drives(orgId);
  const found = await childNamed(orgId, root.id, LORE_FOLDER, 'folder');
  if (found) return found.id;
  const { node } = await diskApi.createFolder(orgId, root.id, LORE_FOLDER, false);
  return node.id;
}

export default function useLorePages() {
  const { organizations } = useAuth();
  // C:\ is the same from every team, so any org with working Disk reaches it:
  // the first whose Disk answers and isn't read-only (a team off the Disk plan
  // 403s, a downgraded one is read-only).
  const orgIds = (organizations || []).map((o) => o.id).filter(isRealOrgId);
  const orgSig = orgIds.join(',');
  const [orgId, setOrgId] = useState(null);
  const [state, setState] = useState({ folderId: null, pages: [], notesId: null, loading: true, error: null });

  const reload = useCallback(async () => {
    // Demo mode: the person's own pages stay off screen; sample ones stand in
    // (LorePageEditor shows sample content for them and saves nothing).
    if (isDemoMode()) {
      setState({ folderId: null, pages: DEMO_PAGES, notesId: DEMO_NOTES_ID, loading: false, error: null });
      return;
    }
    if (!orgSig) {
      setState((s) => ({ ...s, loading: false }));
      return;
    }
    try {
      const found = await writableDiskOrg(orgSig.split(','));
      if (!found) {
        setOrgId(null);
        setState((s) => ({ ...s, loading: false }));
        return;
      }
      setOrgId(found.id);
      const folderId = await ensureFolder(found.id, found.drives);
      const orgId = found.id; // the org this load settled on
      const pages = (await allChildren(orgId, folderId, { type: 'pages', sort: 'name', dir: 'asc' })).filter((n) => n.kind === 'page');
      let notes = pages.find((p) => p.name === NOTES_PAGE);
      if (!notes) notes = (await diskApi.createPage(orgId, folderId, NOTES_PAGE, false)).node;
      setState({ folderId, pages: pages.filter((p) => p.id !== notes.id), notesId: notes.id, loading: false, error: null });
    } catch (e) {
      log.warn('LorePages', `load failed: ${e?.message || e}`);
      setState((s) => ({ ...s, loading: false, error: e }));
    }
  }, [orgSig]);

  useEffect(() => { reload(); }, [reload]);

  const createPage = useCallback(async (name = 'Untitled page') => {
    if (!state.folderId) return null; // demo mode has no folder: nothing is created
    const { node } = await diskApi.createPage(orgId, state.folderId, name, true);
    await reload();
    return node;
  }, [orgId, state.folderId, reload]);

  return { orgId, ...state, createPage, reload };
}
