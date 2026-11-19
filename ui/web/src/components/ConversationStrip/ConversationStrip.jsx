import Icon from '../Icon';
import Avatar from '../Avatar';
import { ProviderIcon } from '../AccountSwitcher/AccountSwitcher';
import { cleanSubject } from '../../lib/cleanSubject';
import { paletteSolid } from '../../lib/spaceColors';
import styles from './ConversationStrip.module.css';

/* Compact, transparent conversation list for embedding over a colored surface
 * (e.g. a treemap cell). Rows are see-through; text colour is driven by the
 * `--q-fg` custom property inherited from the host (defaults to white), so the
 * same strip reads on any background. Row layout:
 *   [channel icon] [from] [subject] [body preview] … [date]
 * The body preview fills the remaining space and is the first thing to truncate.
 * Each message: { id, from, subject, preview, provider, date, attachment } plus
 * the optional Jev chips `priorityChip` / `labelChip` ({ badge, tone, color? },
 * lib/triage.js) and `assignees` ([{ id, name }]) shown right of the preview.
 *
 * `onOpen(m)` (optional) makes each row an interactive target that opens the
 * conversation; clicks stop propagating so a host cell's own click (e.g. the
 * treemap's space drill-in) doesn't also fire. */

export default function ConversationStrip({ messages, className, onOpen, onContextMenu }) {
  const rowProps = (m) => ({
    ...(onOpen ? {
      role: 'button',
      tabIndex: 0,
      onClick: (e) => { e.stopPropagation(); onOpen(m); },
      onKeyDown: (e) => {
        if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); e.stopPropagation(); onOpen(m); }
      },
    } : {}),
    ...(onContextMenu ? { onContextMenu: (e) => onContextMenu(m, e) } : {}),
  });
  return (
    <ul className={[styles.list, className].filter(Boolean).join(' ')}>
      {messages.map((m) => (
        <li key={m.id} className={[styles.row, onOpen ? styles.rowOpen : ''].filter(Boolean).join(' ')} {...rowProps(m)}>
          {m.provider && <span className={styles.channel}><ProviderIcon type={m.provider} size={14} /></span>}
          <span className={styles.from}>{m.from}</span>
          <span className={styles.subject} dir="auto">{cleanSubject(m.subject)}</span>
          {m.preview && <span className={styles.preview}>{m.preview}</span>}
          {m.attachment && <Icon name="paperclip" size={10} className={styles.clip} />}
          {m.priorityChip && <Chip chip={m.priorityChip} />}
          {m.labelChip && <Chip chip={m.labelChip} />}
          {m.assignees?.length > 0 && (
            <span className={styles.assignees} title={m.assignees.map((a) => a.name).join(', ')}>
              {m.assignees.slice(0, 2).map((a) => (
                <span key={a.id || a.name} className={styles.assignee}><Avatar name={a.name} size={16} /></span>
              ))}
              {m.assignees.length > 2 && <span className={styles.assigneeMore}>+{m.assignees.length - 2}</span>}
            </span>
          )}
          <span className={styles.date}>{m.date}</span>
        </li>
      ))}
    </ul>
  );
}

// A custom label with a palette color tints the chip via --chip-color.
function Chip({ chip }) {
  const color = chip.color ? paletteSolid(chip.color) : null;
  return (
    <span
      className={[styles.chip, styles[`tone_${chip.tone}`]].filter(Boolean).join(' ')}
      ref={color ? (el) => { if (el) el.style.setProperty('--chip-color', color); } : undefined}
    >
      {chip.badge}
    </span>
  );
}
