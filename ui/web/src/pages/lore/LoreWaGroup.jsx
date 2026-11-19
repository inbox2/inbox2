import { useEffect, useState } from 'react';
import Icon from '../../components/Icon';
import EntityIcon from '../../components/Lore/EntityIcon';
import LoreItem from '../../components/Lore/LoreItem';
import useLore, { LORE_SCOPE } from '../../hooks/useLore';
import { getDb } from '../../lib/db';
import log from '../../lib/log';
import { waGroupSetTracked, waGroupSetIgnored, waGroupDaySummary } from '../../lib/localWhatsApp';
import { ageLabel } from '../../lib/lore';
import styles from '../../components/Lore/Lore.module.css';

const RECENT_DONE = 8;

/** Local midnight `back` days before today → { key: 'YYYY-MM-DD', from, to, label }. */
function dayOf(back) {
  const now = new Date();
  const start = new Date(now.getFullYear(), now.getMonth(), now.getDate() - back);
  const end = new Date(start.getFullYear(), start.getMonth(), start.getDate() + 1);
  const pad = (n) => String(n).padStart(2, '0');
  const label = back === 0 ? 'Today' : back === 1 ? 'Yesterday'
    : start.toLocaleDateString(undefined, { weekday: 'long', month: 'short', day: 'numeric' });
  return { key: `${start.getFullYear()}-${pad(start.getMonth() + 1)}-${pad(start.getDate())}`, from: start.getTime(), to: end.getTime(), label };
}

/**
 * One day of the group, summarised by the text lane (wa_group_day_summary):
 * today first, ‹ › to step back and forth. Written when a day is opened and
 * cached; a day only gets rewritten once it has newer messages.
 */
function DaySummary({ chatId, name, rev }) {
  const [back, setBack] = useState(0);
  const [state, setState] = useState({ loading: true });
  const day = dayOf(back);
  useEffect(() => {
    let alive = true;
    // A new day starts loading; a reload of the same day keeps its text up meanwhile.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setState((s) => (s.day === day.key ? s : { loading: true }));
    waGroupDaySummary(chatId, name, day.key, day.from, day.to)
      .then((r) => alive && setState({ day: day.key, summary: r.summary, messages: r.messages }))
      .catch((e) => alive && setState({ day: day.key, error: String(e?.message || e) }));
    return () => { alive = false; };
    // day.from/to follow day.key. `rev` changes whenever Lore reloads (Refresh,
    // new messages): the cached day is rewritten only if it has newer ones.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chatId, name, day.key, rev]);

  let body;
  if (state.loading) body = <p className={styles.muted}>Summarising…</p>;
  else if (state.error) body = <p className={styles.muted} role="alert">Couldn't summarise this day: {state.error}</p>;
  else if (!state.messages) body = <p className={styles.muted}>No messages this day.</p>;
  else {
    body = (
      <ul className={styles.daySummary}>
        {state.summary.split('\n').map((l) => l.replace(/^- /, '')).filter(Boolean).map((l) => <li key={l}>{l}</li>)}
      </ul>
    );
  }
  return (
    <>
      <h2 className={styles.h2}>
        {day.label}
        <span className={styles.dayNav}>
          <button type="button" className={styles.iconButton} onClick={() => setBack((b) => b + 1)} aria-label="Day before" title="Day before">
            <Icon name="chevron.left" size={12} />
          </button>
          <button type="button" className={styles.iconButton} onClick={() => setBack((b) => b - 1)} disabled={back === 0} aria-label="Day after" title="Day after">
            <Icon name="chevron.right" size={12} />
          </button>
        </span>
        {!!state.messages && <span className={styles.h2Rule}>{state.messages} {state.messages === 1 ? 'message' : 'messages'}</span>}
      </h2>
      {body}
    </>
  );
}

/**
 * A tracked WhatsApp business group as a Lore page (whatsapp_groups.rs): its
 * open to-dos — yours, and everyone else's you wait on — with who has to do
 * each, what was recently done, and the switch to stop (or start) tracking it.
 * Jev picks the groups; the switches here are the person's word and win:
 * track or not, or ignore it (kept out of Lore entirely, never read). A
 * tracked group also gets its day summary, today first.
 */
export default function LoreWaGroup({ ctx, chatId }) {
  const { lore, open } = ctx;
  const id = Number(chatId);
  const done = useLore({ scope: LORE_SCOPE.DONE });
  const [row, setRow] = useState(null);
  const [busy, setBusy] = useState(false);

  // The group's tracking row: name for a group with nothing open, and the switch.
  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const db = await getDb();
        const rows = db ? await db.select('SELECT chat_name, business, source, ignored FROM wa_groups WHERE chat_id = ?1', [id]) : [];
        if (alive) setRow(rows[0] || null);
      } catch (e) {
        log.warn('LoreWaGroup', `load failed: ${e?.message || e}`);
      }
    })();
    return () => { alive = false; };
  }, [id]);

  const match = (i) => i.group?.chatId === id || (i.isGroup && i.chatId === id);
  const items = lore.items.filter(match);
  const mine = items.filter((i) => !i.todoId || i.mine);
  const theirs = items.filter((i) => i.todoId && !i.mine);
  const recent = done.items.filter(match).sort((a, b) => b.at - a.at).slice(0, RECENT_DONE);
  const name = items[0]?.subject || row?.chat_name || 'WhatsApp group';
  const ignored = !!row?.ignored;
  const tracked = !!row?.business && !ignored;

  // Both switches: what's shown follows at once, and the sidebar lists it or not.
  const flip = async (call, patch, what) => {
    setBusy(true);
    try {
      await call();
      setRow((r) => ({ ...(r || { chat_name: name, business: 0, ignored: 0 }), ...patch }));
      lore.refresh();
      done.refresh();
      ctx.reloadGroups?.();
    } catch (e) {
      log.warn('LoreWaGroup', `${what} failed: ${e?.message || e}`);
    } finally {
      setBusy(false);
    }
  };
  const toggle = () => flip(() => waGroupSetTracked(id, name, !tracked), { business: tracked ? 0 : 1, source: 'user' }, 'set tracked');
  const toggleIgnored = () => flip(() => waGroupSetIgnored(id, name, !ignored), { ignored: ignored ? 0 : 1 }, 'set ignored');

  const list = (rows, empty) => (rows.length
    ? rows.map((i) => <LoreItem key={i.uid} item={i} showBucket inGroup onToggle={lore.complete} onOpen={open} onSendTo={ctx.sendTo} />)
    : <p className={styles.muted}>{empty}</p>);

  return (
    <>
      <div className={styles.cover} aria-hidden="true" />
      <div className={styles.page}>
        <div className={styles.pageIcon}><EntityIcon name={name} kind="org" size="lg" /></div>
        <h1 className={styles.title}>{name}</h1>

        <div className={styles.props}>
          <div className={styles.prop}>
            <span className={styles.propKey}>Type</span>
            <span className={styles.propValue}><span className={styles.tag}>WhatsApp group</span></span>
          </div>
          <div className={styles.prop}>
            <span className={styles.propKey}>Tracking</span>
            <span className={styles.propValue}>
              {ignored
                ? 'Ignored: kept out of Lore, never read'
                : tracked ? (row?.source === 'user' ? 'Tracked (you turned it on)' : 'Tracked: Jev judged it a business group') : 'Not tracked'}
              {' '}
              {!ignored && (
                <button type="button" className={`${styles.button} ${styles.ghost}`} onClick={toggle} disabled={busy}
                  title={tracked ? 'Drops the to-do list, but questions to you still show in Lore.' : 'Get a to-do list for this group and a summary of each day.'}>
                  {tracked ? 'Stop tracking' : 'Track this group'}
                </button>
              )}
              <button type="button" className={`${styles.button} ${styles.ghost}`} onClick={toggleIgnored} disabled={busy}
                title={ignored ? 'Lets this group back into Lore.' : 'Lore stops reading this group and hides its to-dos.'}>
                {ignored ? 'Stop ignoring' : 'Ignore this group'}
              </button>
            </span>
          </div>
          <div className={styles.prop}>
            <span className={styles.propKey}>Last activity</span>
            <span className={styles.propValue}>{items.length ? ageLabel(Math.max(...items.map((i) => i.at))) : '—'}</span>
          </div>
        </div>

        {tracked && <DaySummary key={id} chatId={id} name={name} rev={lore.items} />}

        <h2 className={styles.h2}>Yours <span className={styles.h2Count}>{mine.length}</span></h2>
        {list(mine, 'Nothing open for you here.')}

        <h2 className={styles.h2}>Waiting on others <span className={styles.h2Count}>{theirs.length}</span></h2>
        {list(theirs, tracked ? 'Nobody owes anything here right now.' : 'Track this group to keep everyone’s to-dos.')}

        <h2 className={styles.h2}>Recently done</h2>
        {recent.length ? recent.map((i) => (
          <div key={i.uid} className={styles.history}>
            <Icon name="checkmark.circle.fill" size={14} />
            <span className={styles.historyText}>
              <button type="button" className={styles.itemTitle} onClick={() => open(i)}>{i.title}</button>
            </span>
            <span className={styles.age}>{i.from}</span>
          </div>
        )) : <p className={styles.muted}>Nothing done yet.</p>}
      </div>
    </>
  );
}
