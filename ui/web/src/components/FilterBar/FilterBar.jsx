import { useEffect, useRef, useState } from 'react'
import { MgmtSelect } from '../management'
import FileTypeIcon, { ActionIcon } from '../FileTypeIcon'
import Popover from '../Popover'
import Avatar from '../Avatar'
import { FAMILIES, MODIFIED_WINDOWS, SORT_KEYS, EMPTY_FILTERS, hasActiveFilters, defaultDir, TILE_SIZES } from '../../lib/disk/listing'
import styles from './FilterBar.module.css'

const TYPING = /^(INPUT|TEXTAREA|SELECT)$/

/**
 * Search, filter chips, sort and list/grid toggle over a Disk listing (spec F2).
 * Controlled: it reports changes and fetches nothing. `/` focuses the search.
 *
 *   value     { ...EMPTY_FILTERS (lib/disk/listing.js), sort, dir, view: 'list' | 'grid', tile }
 *             tile: grid tile width in px (TILE_SIZES), set by the slider shown in grid view
 *   onChange  (nextValue) => void
 *   people    [{ id, name, avatar_url }] for the "Modified by" filter
 *   placeholder  search placeholder, e.g. "Search in Marketing"
 */
export default function FilterBar({ value, onChange, people = [], placeholder = 'Search' }) {
  const inputRef = useRef(null)
  const set = (patch) => onChange({ ...value, ...patch })
  const active = hasActiveFilters(value)

  useEffect(() => {
    const onKey = (e) => {
      if (e.key !== '/' || e.metaKey || e.ctrlKey || e.altKey) return
      const t = document.activeElement
      if (t && (TYPING.test(t.tagName) || t.isContentEditable)) return
      e.preventDefault()
      inputRef.current?.focus()
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [])


  return (
    <div className={styles.bar} role="search">
      <label className={styles.search}>
        <ActionIcon name="search" />
        <input
          ref={inputRef}
          type="search"
          value={value.q}
          placeholder={placeholder}
          aria-label="Search files and folders"
          autoComplete="off"
          onChange={(e) => set({ q: e.target.value })}
          onKeyDown={(e) => { if (e.key === 'Escape' && value.q) { e.stopPropagation(); set({ q: '' }) } }}
        />
        <kbd>/</kbd>
      </label>
      {value.q && (
        <button type="button" className={styles.chip} aria-pressed={value.everywhere} onClick={() => set({ everywhere: !value.everywhere })}>
          Everywhere
        </button>
      )}
      <TypeFilter types={value.types} onChange={(types) => set({ types })} />
      <MgmtSelect
        bare
        className={`${styles.select} ${value.modified ? styles.set : ''}`}
        aria-label="Modified"
        options={MODIFIED_WINDOWS}
        value={value.modified}
        onChange={(e) => set({ modified: e.target.value })}
      />
      <PersonFilter people={people} by={value.by} onChange={(by) => set({ by })} />
      <button type="button" className={styles.chip} aria-pressed={value.sealed} onClick={() => set({ sealed: !value.sealed })}>
        Sealed
      </button>
      {active && (
        <button type="button" className={`${styles.chip} ${styles.clear}`} onClick={() => { set(EMPTY_FILTERS); inputRef.current?.focus() }}>
          Clear filters
        </button>
      )}
      <span className={styles.end}>
        <MgmtSelect
          bare
          className={styles.select}
          aria-label="Sort by"
          options={SORT_KEYS}
          value={value.sort}
          onChange={(e) => set({ sort: e.target.value, dir: defaultDir(e.target.value) })}
        />
        <button
          type="button"
          className={styles.dir}
          aria-label={value.dir > 0 ? 'Ascending, switch to descending' : 'Descending, switch to ascending'}
          onClick={() => set({ dir: -value.dir })}
        >
          <ActionIcon name={value.dir > 0 ? 'arrowUp' : 'arrowDown'} />
        </button>
        {value.view === 'grid' && value.tile && (
          <input
            type="range"
            className={styles.size}
            min={TILE_SIZES.min}
            max={TILE_SIZES.max}
            step={TILE_SIZES.step}
            value={value.tile}
            onChange={(e) => set({ tile: Number(e.target.value) })}
            aria-label="Tile size"
            title="Tile size"
          />
        )}
        <span className={styles.seg} role="group" aria-label="View">
          <button type="button" aria-pressed={value.view === 'list'} aria-label="List view" onClick={() => set({ view: 'list' })}>
            <ActionIcon name="list" />
          </button>
          <button type="button" aria-pressed={value.view === 'grid'} aria-label="Grid view" onClick={() => set({ view: 'grid' })}>
            <ActionIcon name="grid" />
          </button>
        </span>
      </span>
    </div>
  )
}

// The glyph for each family in the type list (fileTypes.js icon keys; folders and pages are node kinds).
const FAMILY_ICON = {
  folders: { kind: 'folder' }, pages: { kind: 'page' }, documents: { type: 'word' }, sheets: { type: 'sheet' },
  slides: { type: 'slides' }, images: { type: 'image' }, media: { type: 'video' }, other: { type: 'file' },
}

/* A filter chip that opens a list under it (Popover, carrying .management for Disk's tokens).
 * A click on anything marked data-close closes it; focus lands on its first control. */
function FilterDropdown({ label, ariaLabel, active, children }) {
  const btnRef = useRef(null)
  const listRef = useRef(null)
  const [anchor, setAnchor] = useState(null)
  const closedAt = useRef(0)
  const close = () => { closedAt.current = Date.now(); setAnchor(null); btnRef.current?.focus() }
  // The outside-mousedown close fires before the trigger's click; don't reopen on that click.
  const toggle = () => {
    if (anchor) close()
    else if (Date.now() - closedAt.current > 250) setAnchor(btnRef.current.getBoundingClientRect())
  }
  useEffect(() => { if (anchor) listRef.current?.querySelector('input, button')?.focus() }, [anchor])
  return (
    <>
      <button ref={btnRef} type="button" className={`${styles.chip} ${styles.typeChip}`} aria-pressed={active}
        aria-haspopup="true" aria-expanded={!!anchor} aria-label={ariaLabel} onClick={toggle}>
        {label}
        <ActionIcon name="chevronDown" size={12} />
      </button>
      <Popover open={!!anchor} anchorRect={anchor} placement="bottom" onClose={close} className={`${styles.typeList} management`}>
        <div ref={listRef} role="presentation" onClick={(e) => { if (e.target.closest('[data-close]')) close() }}>{children}</div>
      </Popover>
    </>
  )
}

/* Type filter: "Everything", a family, or "Documents +2", opening a checkbox list.
 * Everything clears the list; each family toggles. Empty means every type. */
function TypeFilter({ types, onChange }) {
  const first = FAMILIES.find((f) => f.value === types[0])
  const label = !types.length ? 'Everything' : types.length === 1 ? first?.label : `${first?.label} +${types.length - 1}`
  const flip = (f) => onChange(types.includes(f) ? types.filter((t) => t !== f) : [...types, f])
  return (
    <FilterDropdown label={label} ariaLabel={`Type: ${label}`} active={types.length > 0}>
      <div role="group" aria-label="Types">
        <label className={styles.typeRow}>
          <MgmtCheckbox  checked={!types.length} onChange={() => onChange([])} />
          <span className={styles.typeIcon}><ActionIcon name="grid" size={22} /></span>
          Everything
        </label>
        <hr className={styles.typeSep} />
        {FAMILIES.map((f) => (
          <label key={f.value} className={styles.typeRow}>
            <MgmtCheckbox  checked={types.includes(f.value)} onChange={() => flip(f.value)} />
            <span className={styles.typeIcon}><FileTypeIcon {...FAMILY_ICON[f.value]} size={30} /></span>
            {f.label}
          </label>
        ))}
      </div>
    </FilterDropdown>
  )
}

/* Modified by: Anyone, or one person, each with their avatar; a pick closes the list. */
function PersonFilter({ people, by, onChange }) {
  const who = people.find((p) => p.id === by)
  const label = who ? who.name : 'Anyone'
  return (
    <FilterDropdown label={label} ariaLabel={`Modified by: ${label}`} active={!!who}>
      <div role="group" aria-label="Modified by">
        {[{ id: '', name: 'Anyone' }, ...people].map((p) => (
          <button key={p.id || 'anyone'} type="button" className={styles.personRow} aria-pressed={(by || '') === p.id}
            data-close onClick={() => onChange(p.id)}>
            <span className={styles.typeIcon}>{p.id ? <Avatar name={p.name} src={p.avatar_url} size={28} /> : <ActionIcon name="share" size={20} />}</span>
            {p.name}
            {(by || '') === p.id && <span className={styles.tickMark}><ActionIcon name="check" size={14} /></span>}
          </button>
        ))}
      </div>
    </FilterDropdown>
  )
}

import { MgmtCheckbox } from '../management';