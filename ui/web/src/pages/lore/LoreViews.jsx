import { useMemo, useState } from 'react';
import Icon from '../../components/Icon';
import { Mention } from '../../components/Lore/EntityIcon';
import LoreItem from '../../components/Lore/LoreItem';
import LorePageEditor from '../../components/Lore/LorePageEditor';
import { LORE_PATH } from '../../components/Lore/openItem';
import PageHistory from '../disk/page/PageHistory';
import useLore, { LORE_SCOPE } from '../../hooks/useLore';
import useLoreAuto from '../../hooks/useLoreAuto';
import { isDemoMode } from '../../lib/demoData';
import Switch from '../../components/Switch/Switch';
import { BUCKET_TAG, LORE_SECTIONS, ageLabel, groupButton, searchItems } from '../../lib/lore';
import styles from '../../components/Lore/Lore.module.css';

/** The page head every non-Today view shares: icon tile, title, one line under it. */
function Head({ icon, title, sub }) {
  return (
    <>
      <div className={`${styles.pageIcon} ${styles.pageIconFlat}`}><Icon name={icon} size={36} /></div>
      <h1 className={styles.title}>{title}</h1>
      {sub && <p className={styles.muted}>{sub}</p>}
    </>
  );
}

/** One bucket as a page (Waiting on others). */
export function LoreBucket({ ctx, bucket, title, icon }) {
  const { lore, open, toEntity } = ctx;
  const items = lore.items.filter((i) => i.bucket === bucket).sort((a, b) => a.at - b.at);
  const rule = LORE_SECTIONS.find((s) => s.bucket === bucket)?.rule;
  return (
    <div className={styles.page}>
      <Head icon={icon} title={title} sub={`${rule}. Oldest first — open one to nudge.`} />
      {items.length
        ? items.map((i) => <LoreItem key={i.uid} item={i} onToggle={lore.complete} onOpen={open} onEntity={toEntity} onSendTo={ctx.sendTo} />)
        : <p className={styles.muted}>{lore.loading ? 'Loading…' : 'Nobody owes you an answer.'}</p>}
    </div>
  );
}

/** Handled for you: the suggestions, each group with its batch button (suggest-only). */
export function LoreHandled({ ctx }) {
  const { lore, open, toEntity } = ctx;
  const { auto, setAuto, saving } = useLoreAuto();
  return (
    <div className={styles.page}>
      <Head icon="archivebox" title="Handled for you" sub="Mail Lore would file away for you. Nothing moves until you press a button — or switch a group to Auto." />
      {lore.today.handled.map((g) => (
        <div key={g.label}>
          <h2 className={styles.h2}>
            {g.title} <span className={styles.h2Count}>{g.items.length}</span>
            <span className={styles.h2Rule}>
              {g.items.length > 0 && (
                <button type="button" className={`${styles.button} ${styles.buttonPrimary}`} onClick={() => lore.completeMany(g.items, g.action)}>
                  {groupButton(g)} all {g.items.length}
                </button>
              )}
            </span>
          </h2>
          <div className={styles.autoRow}>
            <Switch
              id={`lore-auto-${g.label}`}
              label={`Auto: ${g.verb.toLowerCase()} new ${g.title.toLowerCase()}`}
              description="Applies to new mail. On a shared team inbox Lore only ever suggests."
              checked={!!auto[g.label]}
              disabled={saving}
              onChange={(on) => setAuto(g.label, on)}
            />
          </div>
          {g.items.length
            ? g.items.map((i) => <LoreItem key={i.uid} item={i} onToggle={(it) => lore.complete(it, g.action)} onOpen={open} onEntity={toEntity} onSendTo={ctx.sendTo} />)
            : <p className={styles.muted}>None.</p>}
        </div>
      ))}
    </div>
  );
}

/** History: what was ticked off (archived Lore threads), with a way back. */
export function LoreHistory({ ctx }) {
  const { open, toEntity } = ctx;
  const done = useLore({ scope: LORE_SCOPE.DONE });
  const [query, setQuery] = useState('');
  const items = useMemo(() => searchItems(done.items, query).sort((a, b) => b.at - a.at), [done.items, query]);
  return (
    <div className={styles.page}>
      <Head icon="clock.arrow.circlepath" title="History" sub="Recently done Lore threads. Put one back and it returns to Today." />
      <input className={styles.search} type="search" value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Filter history…" aria-label="Filter history" />
      {items.map((i) => (
        <div key={i.uid} className={styles.history}>
          <Icon name="checkmark.circle.fill" size={14} />
          <span className={styles.historyText}>
            <button type="button" className={styles.itemTitle} onClick={() => open(i)}>{i.subject}</button>
            <div className={styles.itemMeta}>
              <Mention domain={i.domain} name={i.from} kind={i.domain ? 'org' : 'person'} onClick={() => toEntity(i.domain ? { kind: 'org', domain: i.domain } : { kind: 'person', address: i.address })} />
            </div>
          </span>
          <span className={`${styles.tag} ${styles[`tag_${i.bucket}`]}`}>{i.labelName || BUCKET_TAG[i.bucket]}</span>
          <span className={styles.age}>{ageLabel(i.at)}</span>
          <button type="button" className={styles.button} onClick={() => done.restore(i)}>Put back</button>
        </div>
      ))}
      {!items.length && <p className={styles.muted}>{done.loading ? 'Loading…' : 'Nothing here yet.'}</p>}
    </div>
  );
}

/** Search across open items and the person's pages. */
export function LoreSearch({ ctx, query }) {
  const { lore, pages, open, toEntity, navigate } = ctx;
  const items = searchItems(lore.items, query);
  const q = query.toLowerCase();
  const pageHits = pages.pages.filter((p) => (p.name || '').toLowerCase().includes(q));
  const orgHits = lore.entities.orgs.filter((o) => o.name.toLowerCase().includes(q) || o.domain.includes(q));
  return (
    <div className={styles.page}>
      <Head icon="magnifyingglass" title={`“${query}”`} sub={`${items.length} open items · ${orgHits.length} organizations · ${pageHits.length} pages`} />
      {orgHits.length > 0 && (
        <>
          <h2 className={styles.h2}>Organizations</h2>
          <div className={styles.propValue}>
            {orgHits.map((o) => <Mention key={o.domain} domain={o.domain} name={o.name} onClick={() => navigate(LORE_PATH.ORG(o.domain))} />)}
          </div>
        </>
      )}
      {pageHits.length > 0 && (
        <>
          <h2 className={styles.h2}>Pages</h2>
          {pageHits.map((p) => (
            <button key={p.id} type="button" className={styles.nav} onClick={() => navigate(LORE_PATH.PAGE(p.id))}>
              <Icon name="doc" size={14} /><span className={styles.navLabel}>{p.name}</span>
            </button>
          ))}
        </>
      )}
      <h2 className={styles.h2}>Open items</h2>
      {items.length
        ? items.map((i) => <LoreItem key={i.uid} item={i} showBucket onToggle={lore.complete} onOpen={open} onEntity={toEntity} onSendTo={ctx.sendTo} />)
        : <p className={styles.muted}>No open item matches.</p>}
    </div>
  );
}

/** One of the person's own Lore pages (a Disk page on C:\), with its version history. */
export function LorePage({ ctx, id }) {
  const { pages } = ctx;
  const [status, setStatus] = useState('');
  const [history, setHistory] = useState(false);
  const node = pages.pages.find((p) => p.id === id);
  if (!pages.orgId && !isDemoMode()) return <div className={styles.page}><p className={styles.muted}>Pages need an inbox2 account with Disk.</p></div>;
  return (
    <div className={styles.page}>
      <Head icon="doc.text.fill" title={node?.name || 'Untitled page'} />
      <div className={styles.prop}>
        <span className={styles.notesStatus}>{status || 'Saved on your Disk (C:\\Lore)'}</span>
        <span className={styles.topbarRight}>
          {!isDemoMode() && (
            <button type="button" className={`${styles.button} ${styles.ghost}`} onClick={() => setHistory(true)}>
              <Icon name="clock.arrow.circlepath" size={12} /> Page history
            </button>
          )}
        </span>
      </div>
      <LorePageEditor key={`${pages.orgId}:${id}`} orgId={pages.orgId} nodeId={id} onStatus={setStatus} />
      {history && (
        <PageHistory orgId={pages.orgId} node={node || { id, name: 'Page' }} canRestore={false} onRestore={() => {}} onClose={() => setHistory(false)} />
      )}
    </div>
  );
}
