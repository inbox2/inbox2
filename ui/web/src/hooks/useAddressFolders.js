import { useCallback, useEffect, useState } from 'react';
import api from '../lib/localFirstApi';
import log from '../lib/log';
import useMailRefresh from './useMailRefresh';
import useRefetchOnFocus from './useRefetchOnFocus';
import { folderPrefKey } from '../lib/addressFolders';

const NONE = [];

/**
 * One MX domain's address folders (GET orgs/:org/folders?domain=), refreshed on
 * new mail, refocus and `reloadKey` changes. `setPref(folder, { inbox | notify })`
 * flips Show in Inbox / the bell, optimistically, and reloads the tree after
 * (Show in Inbox changes what the Inbox counts). No domain → no folders.
 */
export default function useAddressFolders(orgId, domainKey, reloadKey) {
  const [state, setState] = useState({ key: null, folders: NONE });
  const [nonce, setNonce] = useState(0);
  const reload = useCallback(() => setNonce((n) => n + 1), []);
  useMailRefresh(reload);
  useRefetchOnFocus(reload);

  const key = orgId && domainKey ? `${orgId}:${domainKey}` : null;
  useEffect(() => {
    if (!key) return undefined;
    let cancelled = false;
    api.getFolders(orgId, domainKey)
      .then((data) => { if (!cancelled) setState({ key, folders: data.folders || NONE }); })
      .catch((e) => log.warn('Folders', `Load failed: ${e?.message || e}`));
    return () => { cancelled = true; };
  }, [key, orgId, domainKey, nonce, reloadKey]);

  const setPref = useCallback(async (folder, change) => {
    const patch = {};
    if ('inbox' in change) patch.in_inbox = change.inbox;
    if ('notify' in change) patch.notify = change.notify;
    setState((s) => ({ ...s, folders: s.folders.map((f) => (f.key === folder.key ? { ...f, ...patch } : f)) }));
    try {
      await api.updateFolderPrefs(orgId, { address: folderPrefKey(folder), ...change });
    } catch (e) {
      log.warn('Folders', `Saving the setting failed: ${e?.message || e}`);
    }
    reload();
  }, [orgId, reload]);

  // Folders of another domain (still loading the new one) are not shown.
  return { folders: state.key === key ? state.folders : NONE, setPref, reload };
}
