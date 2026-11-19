import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import * as Y from 'yjs';
import RichEditor from '../RichEditor';
import Skeleton from '../Skeleton';
import diskApi from '../../lib/disk/api';
import YjsActionCableProvider from '../../lib/YjsActionCableProvider';
import { PAGE_REPLACED, SEED_CLIENT_ID, base64ToBytes, bytesToBase64, isReplacement, markdownToHtml, toMarkdown } from '../../lib/disk/pages';
import { ROLE, roleAtLeast } from '../../lib/disk/model';
import { registerUnsaved } from '../../lib/unsavedWork';
import { pageExtensions } from '../../pages/disk/page/extensions';
import SlashMenu from '../../pages/disk/page/SlashMenu';
import useAuth from '../../hooks/useAuth';
import { isDemoMode } from '../../lib/demoData';
import styles from './Lore.module.css';

const SAVE_DEBOUNCE_MS = 2000;

/**
 * A Lore page in place: a Disk page (docs/plans/lore.md §3) edited with the
 * Disk page editor's blocks and "/" menu, live over DiskPageChannel and saved
 * as a snapshot a couple of seconds after each change. The trimmed-down twin of
 * PageView — no breadcrumbs, sharing or sealed pages (Lore pages live on C:\
 * and are never sealed). `onStatus` hears "Saved" / "Editing" / "Not saved: …".
 */
// Sample content per demo page (useLorePages' DEMO_PAGES); editable on screen, never saved.
const DEMO_CONTENT = {
  'demo-notes': '<p>Ask Sarah whether the renewal also covers the analytics add-on before replying.</p><ul data-type="taskList"><li data-type="taskItem" data-checked="false"><p>Call the notary about the formation date</p></li><li data-type="taskItem" data-checked="true"><p>Send the signed order form to Northwind</p></li></ul>',
  'demo-launch': '<h2>Launch week</h2><ul data-type="taskList"><li data-type="taskItem" data-checked="true"><p>Freeze the pricing page</p></li><li data-type="taskItem" data-checked="false"><p>Brief support on the new plans</p></li><li data-type="taskItem" data-checked="false"><p>Schedule the announcement</p></li></ul>',
  'demo-hiring': '<h2>Open roles</h2><p>Two engineers and one designer by the end of Q1. Interviews on Tuesdays and Thursdays.</p>',
};

export default function LorePageEditor(props) {
  if (isDemoMode()) return <DemoPage nodeId={props.nodeId} />;
  return <LiveLorePage {...props} />;
}

function DemoPage({ nodeId }) {
  const extensions = useMemo(() => pageExtensions({ orgId: null, onOpenFile: null }), []);
  return (
    <RichEditor
      content={DEMO_CONTENT[nodeId] || '<p></p>'}
      toolbar={false}
      autofocus={false}
      extraExtensions={extensions}
      className={styles.editor}
    />
  );
}

function LiveLorePage({ orgId, nodeId, placeholder, onStatus }) {
  const { user } = useAuth();
  const [loaded, setLoaded] = useState(null); // { doc, provider, markdown }
  const [error, setError] = useState(null);
  const [slash, setSlash] = useState(null);
  const [editor, setEditor] = useState(null);
  const revision = useRef(0);
  const dirty = useRef(false);
  const timer = useRef(null);
  const saving = useRef(null);
  const saveRef = useRef(null); // the latest save, for the follow-up a landed save schedules
  // A markdown-only replacement elsewhere (an agent over MCP) drops the Yjs state:
  // reload it as a new document and keep what was typed here for recovery.
  const [generation, setGeneration] = useState(0);
  const [recovered, setRecovered] = useState(null);
  // Access as the server says it now (the page load's role, then channel updates).
  const [role, setRole] = useState(null);
  const [revoked, setRevoked] = useState(false);
  const editable = roleAtLeast(role, ROLE.EDIT) && !revoked;
  // Channel events beyond the Yjs relay, through a ref so the provider built at
  // load time always calls the latest handler.
  const onChannel = useRef(() => {});
  const status = useRef(onStatus);
  useEffect(() => { status.current = onStatus; }, [onStatus]);

  useEffect(() => {
    let live = true;
    const doc = new Y.Doc();
    let provider;
    diskApi.page(orgId, nodeId).then(({ page, role: r }) => {
      if (!live) return;
      setRole(r);
      if (page.ydoc) Y.applyUpdate(doc, base64ToBytes(page.ydoc), 'server');
      revision.current = page.revision || 0;
      provider = new YjsActionCableProvider(doc, nodeId, {
        user,
        channel: 'DiskPageChannel',
        params: { org_id: orgId, node_id: nodeId },
        ignoreOwn: false,
        syncOnJoin: true,
        onMessage: (m) => onChannel.current(m),
      });
      setLoaded({ doc, provider, markdown: isReplacement(page) ? page.markdown : null });
    }).catch((e) => { if (live) setError(e); });
    return () => {
      live = false;
      provider?.destroy();
      doc.destroy();
    };
  }, [orgId, nodeId, user, generation]);

  const replacedElsewhere = useCallback((ed) => {
    setRecovered(ed ? toMarkdown(ed.getJSON()) : null);
    dirty.current = false;
    clearTimeout(timer.current);
    setEditor(null);
    setLoaded(null);
    setGeneration((g) => g + 1);
    status.current?.('This page changed. Reloaded.');
  }, []);

  const save = useCallback(async () => {
    if (!loaded || !editor || !dirty.current || saving.current) return saving.current;
    dirty.current = false;
    status.current?.('Saving…');
    saving.current = (async () => {
      try {
        for (let tries = 0; ; tries++) {
          try {
            const { page } = await diskApi.savePage(orgId, nodeId, {
              ydoc: bytesToBase64(Y.encodeStateAsUpdate(loaded.doc)),
              markdown: toMarkdown(editor.getJSON()),
              base_revision: revision.current,
            });
            revision.current = page.revision;
            // Edits made while this save was in flight weren't in it: save again.
            if (dirty.current) {
              status.current?.('Editing');
              clearTimeout(timer.current);
              timer.current = setTimeout(() => saveRef.current?.(), SAVE_DEBOUNCE_MS);
            } else status.current?.('Saved');
            return;
          } catch (e) {
            if (e.status !== 409 || tries > 2) throw e;
            // Someone (another tab) saved since our base: merge their snapshot, save on top.
            const { page } = await diskApi.page(orgId, nodeId);
            // Replaced from markdown: never save the old document over it.
            if (isReplacement(page)) { replacedElsewhere(editor); return; }
            Y.applyUpdate(loaded.doc, base64ToBytes(page.ydoc), 'server');
            revision.current = page.revision;
          }
        }
      } catch (e) {
        dirty.current = true;
        status.current?.(`Not saved: ${e.message}`);
      } finally {
        saving.current = null;
      }
    })();
    return saving.current;
  }, [loaded, editor, orgId, nodeId, replacedElsewhere]);
  useEffect(() => { saveRef.current = save; }, [save]);

  useEffect(() => {
    onChannel.current = (m) => {
      if (m.type === 'page_saved') revision.current = Math.max(revision.current, m.revision);
      else if (m.type === 'role_changed') setRole(m.role);
      else if (m.type === 'access_revoked' || m.type === 'rejected') setRevoked(true);
      // An agent (MCP) or another tool replaced the page as markdown: reload it now.
      else if (m.type === PAGE_REPLACED) replacedElsewhere(dirty.current ? editor : null);
    };
  }, [editor, replacedElsewhere]);

  useEffect(() => {
    if (!loaded) return undefined;
    const onUpdate = (_u, origin) => {
      if (origin === loaded.provider || origin === 'server' || !editable) return;
      dirty.current = true;
      status.current?.('Editing');
      clearTimeout(timer.current);
      timer.current = setTimeout(save, SAVE_DEBOUNCE_MS);
    };
    loaded.doc.on('update', onUpdate);
    // Closing or reloading inside the save debounce: save now and ask the browser to wait.
    const beforeUnload = (e) => { if (dirty.current) { save(); e.preventDefault(); } };
    window.addEventListener('beforeunload', beforeUnload);
    return () => {
      loaded.doc.off('update', onUpdate);
      window.removeEventListener('beforeunload', beforeUnload);
      clearTimeout(timer.current);
      save();
    };
  }, [loaded, save, editable]);

  useEffect(() => (editor
    ? registerUnsaved('Lore notes', () => (dirty.current || saving.current ? editor.getText() : ''))
    : undefined), [editor]);

  const onEditor = useCallback((ed) => {
    setEditor(ed);
    // A page with markdown and no Yjs state: seed it under the shared seed id (as PageView does).
    if (loaded?.markdown && ed.isEmpty) {
      markdownToHtml(loaded.markdown).then((html) => {
        const own = loaded.doc.clientID;
        loaded.doc.clientID = SEED_CLIENT_ID;
        try { ed.commands.setContent(html); } finally { loaded.doc.clientID = own; }
      });
    }
  }, [loaded]);

  const extensions = useMemo(() => pageExtensions({ orgId, onOpenFile: null }), [orgId]);

  const onKeyDown = useCallback((view, event) => {
    if (event.key !== '/' || !editable) return false;
    const { $from, empty } = view.state.selection;
    if (!empty || $from.parent.textContent.length) return false;
    const at = $from.pos;
    requestAnimationFrame(() => {
      const c = view.coordsAtPos(at);
      setSlash({ from: at, rect: { top: c.top, bottom: c.bottom, left: c.left, right: c.right, width: 0, height: c.bottom - c.top } });
    });
    return false;
  }, [editable]);

  if (error) return <p className={styles.muted}>Can't open this page. {error.message}</p>;
  if (!loaded) return <Skeleton variant="text" count={3} />;
  const notice = revoked ? "You can't open this page any more." : (!editable ? 'You can read this page. Ask its owner to let you edit.' : null);
  return (
    <>
      {notice && <p className={styles.muted} role="status">{notice}</p>}
      {recovered && (
        <div className={styles.callout} role="status">
          <div>
            <b>This page changed while you were typing.</b> Copy what you need.
            <pre className={styles.recovered}>{recovered}</pre>
            <button type="button" className={styles.button} onClick={() => setRecovered(null)}>Dismiss</button>
          </div>
        </div>
      )}
      <RichEditor
        yjsDoc={loaded.doc}
        provider={loaded.provider}
        editable={editable}
        toolbar={false}
        autofocus={false}
        placeholder={editable ? (placeholder || 'Type / to add a heading, to-do or table') : ''}
        extraExtensions={extensions}
        onKeyDown={onKeyDown}
        onEditor={onEditor}
        className={styles.editor}
      />
      {slash && editor && (
        <SlashMenu
          editor={editor}
          from={slash.from}
          anchorRect={slash.rect}
          onClose={() => setSlash(null)}
          menuClassName={`${styles.lore} ${styles.slashMenu}`}
          itemClassName={styles.slashItem}
        />
      )}
    </>
  );
}
