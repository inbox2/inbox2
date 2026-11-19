import { useEffect, useMemo, useRef, useState } from 'react';
import { useLocation } from 'react-router';
import Icon from '../../components/Icon';
import Checkbox from '../../components/Checkbox/Checkbox';
import EntityIcon, { Mention } from '../../components/Lore/EntityIcon';
import LoreGroup from '../../components/Lore/LoreGroup';
import LorePageEditor from '../../components/Lore/LorePageEditor';
import { LORE_PATH } from '../../components/Lore/openItem';
import useBrand from '../../hooks/useBrand';
import { BUCKET_TAG, LORE_BUCKET, ageLabel, domainLabel, groupButton } from '../../lib/lore';
import styles from '../../components/Lore/Lore.module.css';

const COVER_ORGS = 6;
const VIEW = { BUCKET: 'bucket', TABLE: 'table', ORG: 'org' };
const VIEWS = [
  { key: VIEW.BUCKET, label: 'By bucket', icon: 'list.bullet.rectangle' },
  { key: VIEW.TABLE, label: 'Table', icon: 'square.grid.2x2' },
  { key: VIEW.ORG, label: 'By organization', icon: 'globe' },
];

const todayLabel = () => new Date().toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' });

/** One "Read later" card: the sender domain's cover image when it has one, else the opening lines. */
function ReadCard({ item, onOpen, onEntity }) {
  const brand = useBrand(item.domain);
  return (
    <div className={styles.card}>
      <button type="button" className={styles.cardCover} onClick={() => onOpen(item)} aria-label={`Open "${item.subject}"`}>
        {brand?.image
          ? <img className={styles.cardImage} src={brand.image} alt="" />
          : <span className={`${styles.cardText} ${styles.cardBody}`}>{item.detail}</span>}
      </button>
      <div className={styles.cardBody}>
        <div className={styles.cardTitle}>{item.subject}</div>
        {brand?.image && <div className={styles.cardText}>{item.detail}</div>}
        <div className={styles.cardFoot}>
          <Mention domain={item.domain} name={brand?.name || item.from} kind={item.domain ? 'org' : 'person'} onClick={() => onEntity(item.domain ? { kind: 'org', domain: item.domain } : { kind: 'person', address: item.address })} />
          <span>{ageLabel(item.at)}</span>
        </div>
      </div>
    </div>
  );
}

/**
 * Today — the Lore home page: cover of today's organizations, properties, a
 * brief, Do first, every open item as an inline database (three views), the
 * Read-later gallery, the Handled-for-you toggle and the person's own notes.
 */
export default function LoreToday({ ctx }) {
  const { lore, pages, open, toEntity, navigate } = ctx;
  const { today, items, entities, loading, complete, completeMany } = lore;
  const [view, setView] = useState(VIEW.BUCKET);
  const [handledOpen, setHandledOpen] = useState(true);
  const [notesStatus, setNotesStatus] = useState('');
  // /lore#notes (the sidebar's "Lore notes") scrolls to the notes and focuses them.
  const { hash } = useLocation();
  const notesRef = useRef(null);
  useEffect(() => {
    if (hash !== '#notes' || !notesRef.current) return;
    notesRef.current.scrollIntoView({ block: 'start' });
    notesRef.current.querySelector('[contenteditable]')?.focus();
  }, [hash, pages.notesId]);

  const reads = today.sections.find((s) => s.bucket === LORE_BUCKET.READ)?.items || [];
  const listSections = today.sections.filter((s) => s.bucket !== LORE_BUCKET.READ);
  // "Open work" = one set for all three views: everything open except Do first
  // (listed above it) and Read later (its own gallery below).
  const openItems = useMemo(() => listSections.flatMap((x) => x.items), [listSections]);
  const handledCount = today.handled.reduce((n, g) => n + g.items.length, 0);
  const sources = new Set(items.map((i) => i.orgId || i.accountKey)).size;
  const waiting = today.sections.find((s) => s.bucket === LORE_BUCKET.WAITING)?.items.length || 0;
  const byOrg = useMemo(() => {
    const groups = new Map();
    for (const i of openItems) {
      const key = i.domain || i.address;
      if (!groups.has(key)) groups.set(key, { key, domain: i.domain, address: i.address, name: i.domain ? domainLabel(i.domain) : i.from, items: [] });
      groups.get(key).items.push(i);
    }
    return [...groups.values()].sort((a, b) => b.items.length - a.items.length);
  }, [openItems]);

  // One single-thread group per item where a view lists threads, not groups (by organization).
  const row = (item, extra = {}) => rowOf({ uid: item.uid, lead: item, items: [item] }, extra);
  const rowOf = (g, extra = {}) => (
    <LoreGroup key={g.uid} group={g} lore={lore} onOpen={open} onEntity={toEntity} onSendTo={ctx.sendTo} {...extra} />
  );

  return (
    <>
      <div className={styles.cover} aria-label="Today's organizations">
        {entities.orgs.slice(0, COVER_ORGS).map((o) => (
          <button key={o.domain} type="button" className={styles.coverTile} onClick={() => navigate(LORE_PATH.ORG(o.domain))} aria-label={o.name}>
            <EntityIcon domain={o.domain} name={o.name} size="md" />
          </button>
        ))}
      </div>
      <div className={styles.page}>
        <div className={styles.pageIcon}><Icon name="checkmark.circle" size={40} /></div>
        <h1 className={styles.title}>Today — {todayLabel()}</h1>

        <div className={styles.props}>
          <div className={styles.prop}><span className={styles.propKey}><Icon name="checkmark.circle" size={13} />Open</span><span className={styles.propValue}>{loading ? '…' : `${today.open} items`}</span></div>
          <div className={styles.prop}><span className={styles.propKey}><Icon name="clock" size={13} />Waiting on others</span><span className={styles.propValue}>{waiting}</span></div>
          <div className={styles.prop}><span className={styles.propKey}><Icon name="archivebox" size={13} />Handled for you</span><span className={styles.propValue}><span className={`${styles.tag} ${styles.tag_handled}`}>{handledCount} waiting for your OK</span></span></div>
          <div className={styles.prop}><span className={styles.propKey}><Icon name="tray" size={13} />Mailboxes</span><span className={styles.propValue}>{sources}</span></div>
          <div className={styles.prop}><span className={styles.propKey}><Icon name="sparkles" size={13} />Sorted by</span><span className={styles.propValue}>Jev triage labels and priority</span></div>
        </div>

        {today.first.length > 0 && (
          <div className={styles.callout}>
            <span className={styles.calloutIcon}><Icon name="sparkles" size={18} /></span>
            <div>
              <b>Brief.</b> {today.first.length === 1 ? 'One thing matters most today: ' : `${today.first.length} things matter most today: `}
              {today.first.map(({ lead: i }, n) => (
                <span key={i.uid}>
                  {n > 0 && (n === today.first.length - 1 ? ' and ' : ', ')}
                  <b>{i.title}</b> from{' '}
                  <Mention
                    domain={i.domain}
                    name={i.from}
                    kind={i.domain ? 'org' : 'person'}
                    onClick={() => toEntity(i.domain ? { kind: 'org', domain: i.domain } : { kind: 'person', address: i.address })}
                  />
                </span>
              ))}
              .{waiting > 0 && ` ${waiting} ${waiting === 1 ? 'thread is' : 'threads are'} waiting on someone else.`}
            </div>
          </div>
        )}

        <h2 className={styles.h2}>Do first <span className={styles.h2Rule}>Highest Jev priority among what needs you</span></h2>
        {today.first.length ? today.first.map((g) => rowOf(g)) : <p className={styles.muted}>{loading ? 'Loading…' : 'Nothing needs you right now.'}</p>}

        <h2 className={styles.h2}>Open work <span className={styles.h2Count}>{openItems.length}</span></h2>
        <div className={styles.viewTabs} role="group" aria-label="Open work view">
          {VIEWS.map((v) => (
            <button
              key={v.key}
              type="button"
              aria-pressed={view === v.key}
              className={`${styles.viewTab} ${view === v.key ? styles.viewTabActive : ''}`}
              onClick={() => setView(v.key)}
            >
              <Icon name={v.icon} size={12} />{v.label}
            </button>
          ))}
        </div>

        {view === VIEW.BUCKET && listSections.map((s) => s.items.length > 0 && (
          <div key={s.bucket}>
            <h3 className={styles.h3}>
              <span className={`${styles.dot} ${styles[`dot_${s.tone}`]}`} />
              {s.title} <span className={styles.h2Count}>{s.items.length}</span>
              <span className={styles.h2Rule}>{s.rule}</span>
            </h3>
            {s.groups.map((g) => rowOf(g))}
          </div>
        ))}

        {view === VIEW.TABLE && (
          <div className={styles.tableWrap}>
            <table className={styles.table} aria-label="Open work">
              <thead>
                <tr>
                  <th scope="col" className={styles.cellCheck}><span className={styles.srOnly}>Done</span></th>
                  <th scope="col">Name</th>
                  <th scope="col">Bucket</th>
                  <th scope="col">From</th>
                  <th scope="col">Age</th>
                </tr>
              </thead>
              <tbody>
                {openItems.map((i) => (
                  <tr key={i.uid}>
                    <td className={styles.cellCheck}>
                      <Checkbox className={styles.check} checked={false} onChange={() => complete(i)} aria-label={`Done — archive "${i.subject}"`} />
                    </td>
                    <td className={styles.cellName}><button type="button" className={styles.itemTitle} onClick={() => open(i)}>{i.subject}</button></td>
                    <td><span className={`${styles.tag} ${styles[`tag_${i.bucket}`]}`}>{i.labelName || BUCKET_TAG[i.bucket]}</span></td>
                    <td>
                      <Mention domain={i.domain} name={i.from} kind={i.domain ? 'org' : 'person'} onClick={() => toEntity(i.domain ? { kind: 'org', domain: i.domain } : { kind: 'person', address: i.address })} />
                    </td>
                    <td>{ageLabel(i.at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            <div className={styles.tableFoot}>{openItems.length} open · ticking a row archives its email</div>
          </div>
        )}

        {view === VIEW.ORG && byOrg.map((g) => (
          <div key={g.key}>
            <h3 className={styles.h3}>
              <EntityIcon domain={g.domain} name={g.name} kind={g.domain ? 'org' : 'person'} size="md" />
              {g.name} <span className={styles.h2Count}>{g.items.length}</span>
            </h3>
            {g.items.map((i) => row(i, { showBucket: true }))}
          </div>
        ))}

        {reads.length > 0 && (
          <>
            <h2 className={styles.h2}>Read later <span className={styles.h2Count}>{reads.length}</span><span className={styles.h2Rule}>Kept and summarised · covers come from the sender's own site</span></h2>
            <div className={styles.gallery}>
              {reads.map((i) => <ReadCard key={i.uid} item={i} onOpen={open} onEntity={toEntity} onSendTo={ctx.sendTo} />)}
            </div>
          </>
        )}

        <h2 className={styles.h2}>Handled for you</h2>
        <button type="button" className={styles.toggle} onClick={() => setHandledOpen((v) => !v)} aria-expanded={handledOpen}>
          <Icon name="chevron.right" size={11} className={`${styles.chevron} ${handledOpen ? styles.chevronOpen : ''}`} />
          {handledCount ? `${handledCount} threads Lore would file away — nothing moves until you say so` : 'Nothing to file away right now'}
        </button>
        {handledOpen && handledCount > 0 && (
          <div className={styles.toggleBody}>
            {today.handled.filter((g) => g.items.length).map((g) => (
              <div className={styles.handledRow} key={g.label}>
                <span className={`${styles.tag} ${styles.tag_handled}`}>Suggest</span>
                <span className={styles.handledText}><b>{g.items.length}</b> {g.title} → {g.verb.toLowerCase()}</span>
                <button type="button" className={styles.button} onClick={() => navigate(LORE_PATH.HANDLED)}>Review</button>
                <button type="button" className={`${styles.button} ${styles.buttonPrimary}`} onClick={() => completeMany(g.items, g.action)}>
                  {groupButton(g)} {g.items.length}
                </button>
              </div>
            ))}
          </div>
        )}

        <h2 className={styles.h2}>My notes <span className={styles.h2Rule}>{notesStatus || 'These are your personal notes'}</span></h2>
        <div className={styles.notes} id="notes" ref={notesRef}>
          {pages.notesId
            ? <LorePageEditor key={`${pages.orgId}:${pages.notesId}`} orgId={pages.orgId} nodeId={pages.notesId} onStatus={setNotesStatus} />
            : <p className={styles.muted}>{pages.loading ? 'Loading…' : pages.error ? `Can't open your notes. ${pages.error.message || ''}` : 'You need Disk to keep notes here.'}</p>}
        </div>
      </div>
    </>
  );
}
