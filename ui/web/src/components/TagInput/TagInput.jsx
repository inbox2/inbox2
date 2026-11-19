import { useState, useRef, useCallback } from 'react';
import Icon from '../Icon';
import styles from './TagInput.module.css';

/**
 * Tag input — chips inline with a text input.
 *
 * Props:
 *   values       — Array<{ email, name? }>
 *   onChange      — (values) => void
 *   placeholder   — input placeholder when empty
 *   suggestions   — Array<{ email, name?, total? }> filtered externally
 *   onQueryChange — (query: string) => void — called as user types
 */
export default function TagInput({ values = [], onChange, placeholder = '', suggestions = [], onQueryChange }) {
  const [query, setQuery] = useState('');
  const [focused, setFocused] = useState(false);
  const [highlight, setHighlight] = useState(0);
  const inputRef = useRef(null);

  const acOpen = focused && suggestions.length > 0 && query.trim().length > 0;

  const addValue = useCallback((entry) => {
    if (values.some(v => v.email === entry.email)) return;
    onChange([...values, entry]);
    setQuery('');
    setHighlight(0);
    onQueryChange?.('');
  }, [values, onChange, onQueryChange]);

  const removeValue = useCallback((email) => {
    onChange(values.filter(v => v.email !== email));
  }, [values, onChange]);

  const handleInputChange = useCallback((e) => {
    const val = e.target.value;
    setQuery(val);
    setHighlight(0);
    onQueryChange?.(val);
  }, [onQueryChange]);

  const handleKeyDown = useCallback((e) => {
    if (acOpen && suggestions.length > 0) {
      if (e.key === 'ArrowDown') { e.preventDefault(); setHighlight(i => Math.min(i + 1, suggestions.length - 1)); return; }
      if (e.key === 'ArrowUp') { e.preventDefault(); setHighlight(i => Math.max(i - 1, 0)); return; }
      if (e.key === 'Enter' || e.key === 'Tab') {
        e.preventDefault();
        addValue({ email: suggestions[highlight].email, name: suggestions[highlight].name });
        return;
      }
    }
    if (e.key === 'Enter') {
      e.preventDefault();
      const email = query.trim().toLowerCase();
      if (email && email.includes('@')) {
        addValue({ email, name: null });
      }
    }
    if (e.key === 'Backspace' && !query && values.length > 0) {
      removeValue(values[values.length - 1].email);
    }
    if (e.key === 'Escape') {
      setFocused(false);
    }
  }, [acOpen, suggestions, highlight, query, values, addValue, removeValue]);

  return (
    <div className={styles.wrap} role="presentation" onClick={() => inputRef.current?.focus()}>
      <div className={styles.inner}>
        {values.map(v => (
          <span key={v.email} className={styles.tag}>
            <span className={styles.tagLabel}>{v.name || v.email}</span>
            <button type="button" className={styles.tagRemove} onMouseDown={(e) => { e.preventDefault(); e.stopPropagation(); removeValue(v.email); }}>
              <Icon name="xmark" size={8} />
            </button>
          </span>
        ))}
        <input
          ref={inputRef}
          className={styles.input}
          type="text"
          value={query}
          onChange={handleInputChange}
          onKeyDown={handleKeyDown}
          onBlur={() => {
            // Commit a typed-but-uncommitted recipient when focus leaves (e.g.
            // clicking Send), so it isn't silently dropped. Suggestion clicks
            // use mousedown+preventDefault, so they don't trigger this blur.
            const email = query.trim().toLowerCase()
            if (email.includes('@')) addValue({ email, name: null })
            setTimeout(() => setFocused(false), 200)
          }}
          onFocus={() => setFocused(true)}
          placeholder={values.length === 0 ? placeholder : ''}
          size={Math.max(1, query.length || 12)}
        />
      </div>
      {acOpen && (
        <div className={styles.dropdown}>
          {suggestions.map((s, i) => {
            const initials = (s.name || s.email[0] || '?').split(' ').map(w => w[0]).join('').toUpperCase().slice(0, 2);
            return (
              <button
                key={s.email}
                type="button"
                className={`${styles.item}${i === highlight ? ` ${styles.itemActive}` : ''}`}
                onMouseDown={(e) => { e.preventDefault(); addValue({ email: s.email, name: s.name }); }}
                onMouseEnter={() => setHighlight(i)}
              >
                <span className={styles.avatar}>{initials}</span>
                <div className={styles.info}>
                  {s.name && <span className={styles.name}>{s.name}</span>}
                  <span className={styles.email}>{s.email}</span>
                </div>
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}
