import { useCallback, useId, useMemo, useRef, useState } from 'react';
import useDismiss from '../../hooks/useDismiss';
import styles from './SearchSelect.module.css';

/* A dropdown you can type into: a 38px trigger like the settings inputs, a
 * search box, and a list filtered by label or value. Each option may carry an
 * `icon` (a flag emoji, say) shown before its label. Keyboard: Enter, Space or
 * ArrowDown opens it; arrows move; Enter picks; Escape closes and returns focus.
 * MgmtSelect stays the plain choice when nobody needs to search or see icons.
 *
 *   <SearchSelect id="language" value="en" onChange={setLang}
 *     options={[{ value: 'en', label: 'English', icon: '🇬🇧' }]} /> */
export default function SearchSelect({ id, value, onChange, options, placeholder = 'Search', label, disabled = false }) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [active, setActive] = useState(0);
  const rootRef = useRef(null);
  const triggerRef = useRef(null);
  const listId = useId();

  const close = useCallback(() => { setOpen(false); triggerRef.current?.focus(); }, []);
  useDismiss(rootRef, close, open);

  const matches = useMemo(() => {
    const q = query.trim().toLowerCase();
    return q ? options.filter((o) => o.label.toLowerCase().includes(q) || String(o.value).toLowerCase().includes(q)) : options;
  }, [options, query]);

  const current = options.find((o) => o.value === value);
  const show = () => {
    setQuery('');
    setActive(Math.max(0, options.findIndex((o) => o.value === value)));
    setOpen(true);
  };
  const pick = (o) => { onChange(o.value); close(); };

  const onTriggerKey = (e) => {
    if (['Enter', ' ', 'ArrowDown'].includes(e.key)) { e.preventDefault(); show(); }
  };
  const onSearchKey = (e) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); setActive((i) => Math.min(i + 1, matches.length - 1)); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setActive((i) => Math.max(i - 1, 0)); }
    else if (e.key === 'Enter') { e.preventDefault(); if (matches[active]) pick(matches[active]); }
    else if (e.key === 'Tab') setOpen(false);
  };

  return (
    <div className={styles.root} ref={rootRef}>
      <button
        id={id}
        ref={triggerRef}
        type="button"
        className={styles.trigger}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={label}
        disabled={disabled}
        onClick={() => (open ? close() : show())}
        onKeyDown={onTriggerKey}
      >
        {current?.icon && <span className={styles.icon} aria-hidden="true">{current.icon}</span>}
        <span className={styles.value}>{current?.label ?? value}</span>
        <span className={styles.chevron} aria-hidden="true">▾</span>
      </button>

      {open && (
        <div className={styles.panel}>
          <input
            autoFocus
            className={styles.search}
            type="text"
            role="combobox"
            aria-controls={listId}
            aria-expanded="true"
            aria-activedescendant={matches[active] ? `${listId}-${matches[active].value}` : undefined}
            placeholder={placeholder}
            aria-label={label ? `Search: ${label}` : placeholder}
            value={query}
            onChange={(e) => { setQuery(e.target.value); setActive(0); }}
            onKeyDown={onSearchKey}
          />
          <ul className={styles.list} role="listbox" id={listId} aria-label={label}>
            {matches.map((o, i) => (
              <li
                key={o.value}
                id={`${listId}-${o.value}`}
                role="option"
                aria-selected={o.value === value}
                className={[styles.option, i === active && styles.highlight, o.value === value && styles.selected].filter(Boolean).join(' ')}
                onMouseEnter={() => setActive(i)}
                onMouseDown={(e) => e.preventDefault()}
                onClick={() => pick(o)}
                onKeyDown={(e) => { if (e.key === 'Enter') pick(o); }}
              >
                {o.icon && <span className={styles.icon} aria-hidden="true">{o.icon}</span>}
                <span className={styles.value}>{o.label}</span>
              </li>
            ))}
            {matches.length === 0 && <li className={styles.empty}>No match</li>}
          </ul>
        </div>
      )}
    </div>
  );
}
