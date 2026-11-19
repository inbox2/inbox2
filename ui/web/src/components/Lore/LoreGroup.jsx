import { useState } from 'react';
import LoreItem from './LoreItem';
import styles from './Lore.module.css';

/**
 * One Lore entry from groupItems(): a single thread renders as a plain row; two
 * or more about the same thing (an invoice and its reminder) render as one row
 * led by the most urgent, ticking all of them off, unfolding to the emails.
 *   lore — useLore() (complete / completeMany); the rest is passed to LoreItem
 */
export default function LoreGroup({ group, lore, action, tone, ...rowProps }) {
  const [open, setOpen] = useState(false);
  const many = group.items.length > 1;
  const tick = (x) => (Array.isArray(x) ? lore.completeMany(x, action) : lore.complete(x, action));
  return (
    <div className={many && open ? styles.groupOpen : undefined}>
      <LoreItem
        {...rowProps}
        tone={tone}
        item={group.lead}
        group={many ? group : null}
        expanded={open}
        onExpand={() => setOpen((v) => !v)}
        onToggle={tick}
      />
      {many && open && (
        <div className={styles.groupChildren}>
          {group.items.map((i) => (
            <LoreItem key={i.uid} {...rowProps} item={i} compact onToggle={tick} />
          ))}
        </div>
      )}
    </div>
  );
}
