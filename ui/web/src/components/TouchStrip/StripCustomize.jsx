import { useEffect, useState } from 'react';
import { DndContext, KeyboardSensor, PointerSensor, closestCenter, useSensor, useSensors } from '@dnd-kit/core';
import { SortableContext, arrayMove, horizontalListSortingStrategy, sortableKeyboardCoordinates } from '@dnd-kit/sortable';
import Modal from '../Modal/Modal';
import Button from '../Button/Button';
import SegmentedControl from '../SegmentedControl/SegmentedControl';
import Icon from '../Icon';
import api from '../../lib/api';
import useDebounce from '../../hooks/useDebounce';
import useSortableNode from '../../hooks/useSortableNode';
import { WIDGET_COMPONENTS } from './widgetMap';
import {
  STRIP_ITEMS, STRIP_WIDGETS, STOCK_SIZE, CRYPTO_CURRENCIES, stripLimit, shortLabel,
  localTimeZone, minutesInZone, relativeOffset, formatMinutes,
  useStripConfig, setStripConfig, resetStripConfig,
} from '../../lib/touchStrip';
import styles from './TouchStrip.module.css';
import { MgmtCheckbox } from '../management';

// "Customize Touch Strip" — after macOS's Customize Touch Bar sheet: a palette
// of widgets (add / remove), per-widget settings, and the strip itself at the
// bottom as a row of keys you drag to reorder. Every edit applies live.

const searchPlaces = (q) => api.stripPlaces(q).then((r) => r.places);
const searchSymbols = (q) => api.stripSymbols(q).then((r) => r.matches);

export default function StripCustomize({ open, onClose }) {
  const config = useStripConfig();
  const [selected, setSelected] = useState('clocks');
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 4 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  );

  const toggle = (id) => setStripConfig((c) => ({
    ...c, items: c.items.includes(id) ? c.items.filter((i) => i !== id) : [...c.items, id],
  }));
  const onDragEnd = ({ active, over }) => {
    if (!over || active.id === over.id) return;
    setStripConfig((c) => ({ ...c, items: arrayMove(c.items, c.items.indexOf(active.id), c.items.indexOf(over.id)) }));
  };

  return (
    <Modal open={open} onClose={onClose} className={styles.sheet} showClose={false}>
      <header className={styles.sheetHead}>
        <div className={styles.sheetTitle}>
          <h2>Customize Touch Strip</h2>
          <p>Switch widgets on or off and tune each one. Drag the order row to rearrange. Syncs to your account.</p>
        </div>
        <Button variant="ghost" onClick={resetStripConfig}>Restore defaults</Button>
        <Button onClick={onClose}>Done</Button>
      </header>

      <div className={styles.sheetBody}>
        <div className={styles.palette}>
          {STRIP_ITEMS.map((id) => {
            const w = STRIP_WIDGETS[id];
            const on = config.items.includes(id);
            const Preview = WIDGET_COMPONENTS[id];
            return (
              <div key={id} className={styles.tile} data-selected={selected === id ? 'true' : undefined} data-off={on ? undefined : 'true'}>
                {/* The real key with live data — look, don't touch. */}
                <div className={styles.tilePreview} inert aria-hidden="true">
                  <Preview config={config} />
                </div>
                <div className={styles.tileFoot}>
                  <span className={styles.tileIcon}><Icon name={w.icon} size={15} /></span>
                  <span className={styles.tileCopy}>
                    <span className={styles.tileName}>{w.label}</span>
                    <span className={styles.tileHint}>{w.hint}</span>
                  </span>
                  <button
                    type="button"
                    role="switch"
                    aria-checked={on}
                    aria-label={`Show ${w.label} in the strip`}
                    className={styles.switch}
                    onClick={() => toggle(id)}
                  />
                </div>
                <button type="button" className={styles.tileSelect} onClick={() => setSelected(id)} aria-pressed={selected === id} aria-label={`${w.label} settings`} />
              </div>
            );
          })}
        </div>
        <aside className={styles.settings} aria-label={`${STRIP_WIDGETS[selected].label} settings`}>
          <div className={styles.settingsHead}>
            <span className={styles.tileIcon}><Icon name={STRIP_WIDGETS[selected].icon} size={15} /></span>
            <h3>{STRIP_WIDGETS[selected].label}</h3>
          </div>
          <WidgetSettings id={selected} config={config} />
        </aside>
      </div>

      <footer className={styles.orderRow}>
        <span className={styles.orderLabel}>Order</span>
        <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={onDragEnd}>
          <SortableContext items={config.items} strategy={horizontalListSortingStrategy}>
            {config.items.map((id) => (
              <PreviewKey key={id} id={id} selected={selected === id} onSelect={() => setSelected(id)} onRemove={() => toggle(id)} />
            ))}
          </SortableContext>
        </DndContext>
        {config.items.length === 0 && <span className={styles.empty}>The strip is empty.</span>}
      </footer>
    </Modal>
  );
}

function PreviewKey({ id, selected, onSelect, onRemove }) {
  const { ref, attributes, listeners, isDragging } = useSortableNode(id);
  const w = STRIP_WIDGETS[id];
  return (
    <div ref={ref} className={styles.orderKey} data-dragging={isDragging ? 'true' : undefined} data-selected={selected ? 'true' : undefined}>
      <button type="button" className={styles.orderHandle} {...attributes} {...listeners} onClick={onSelect} aria-label={`${w.label} — drag to reorder`}>
        <Icon name="line.3.horizontal" size={11} className={styles.grip} />
        <Icon name={w.icon} size={13} />
        <span>{w.label}</span>
      </button>
      <button type="button" className={styles.iconButton} onClick={onRemove} aria-label={`Remove ${w.label}`}>
        <Icon name="xmark" size={8} />
      </button>
    </div>
  );
}

// ── Per-widget settings ──────────────────────────────────────────────────────

const update = (section, fn) => setStripConfig((c) => ({ ...c, [section]: fn(c[section]) }));
const setOption = (key, value) => setStripConfig((c) => ({ ...c, options: { ...c.options, [key]: value } }));
const removeAt = (section, index) => update(section, (list) => list.filter((_, i) => i !== index));
const editAt = (section, index, patch) => update(section, (list) => list.map((row, i) => (i === index ? { ...row, ...patch } : row)));
const addTo = (section, row, same) => update(section, (list) => (
  list.length >= stripLimit(section) || list.some((r) => same(r, row)) ? list : [...list, row]
));

function RemoveButton({ label, onClick }) {
  return (
    <button type="button" className={styles.iconButton} onClick={onClick} aria-label={`Remove ${label}`}>
      <Icon name="xmark" size={8} />
    </button>
  );
}

function WidgetSettings({ id, config }) {
  switch (id) {
    case 'clocks': return <ClockSettings config={config} />;
    case 'weather': return <WeatherSettings config={config} />;
    case 'stocks': return <StockSettings config={config} />;
    case 'crypto': return <CryptoSettings config={config} />;
    case 'news': return <NewsSettings config={config} />;
    default:
      return <p className={styles.note}>Shows the public IP address the inbox2 API sees, the country and ISP, and flags VPN and proxy exits. Click the key to copy the address.</p>;
  }
}

function ClockSettings({ config }) {
  const now = new Date();
  const base = localTimeZone();
  return (
    <>
      <ul className={styles.rows}>
        {config.clocks.map((c, i) => (
          <li key={`${c.tz}-${i}`} className={styles.row}>
            <input
              className={styles.shortInput}
              value={c.label}
              maxLength={4}
              onChange={(e) => editAt('clocks', i, { label: e.target.value.toUpperCase() })}
              aria-label={`Label for ${c.tz}`}
            />
            <span className={styles.rowMain} title={c.tz}>{c.tz.split('/').pop().replace(/_/g, ' ')}</span>
            <span className={styles.rowMeta}>
              {`${formatMinutes(minutesInZone(c.tz, now))}${relativeOffset(c.tz, base, now) ? ` · ${relativeOffset(c.tz, base, now)}` : ''}`}
            </span>
            <RemoveButton label={c.label} onClick={() => removeAt('clocks', i)} />
          </li>
        ))}
      </ul>
      <SearchAdd
        placeholder="Add a city…"
        search={searchPlaces}
        disabled={config.clocks.length >= stripLimit('clocks')}
        describe={(p) => [p.name, p.region, p.country].filter(Boolean).join(', ')}
        onPick={(p) => p.timezone && addTo('clocks', { label: shortLabel(p.name), tz: p.timezone }, (a, b) => a.tz === b.tz && a.label === b.label)}
      />
      <p className={styles.note}>Tap the clocks key for a meeting planner: each city&rsquo;s 09:00–17:00 on your day, and when you all overlap.</p>
    </>
  );
}

function WeatherSettings({ config }) {
  const here = config.places.some((p) => p.current);
  const toggleHere = () => update('places', (list) => (here ? list.filter((p) => !p.current) : [{ current: true }, ...list].slice(0, stripLimit('places'))));
  return (
    <>
      <label className={styles.check}>
        <MgmtCheckbox  checked={here} onChange={toggleHere} />
        Weather where I am (located from your IP address)
      </label>
      <ul className={styles.rows}>
        {config.places.map((p, i) => (p.current ? null : (
          <li key={`${p.lat},${p.lon}`} className={styles.row}>
            <span className={styles.rowMain}>{p.label}</span>
            <RemoveButton label={p.label} onClick={() => removeAt('places', i)} />
          </li>
        )))}
      </ul>
      <SearchAdd
        placeholder="Add a city…"
        search={searchPlaces}
        disabled={config.places.length >= stripLimit('places')}
        describe={(p) => [p.name, p.region, p.country].filter(Boolean).join(', ')}
        onPick={(p) => addTo('places', { label: p.name, lat: p.lat, lon: p.lon }, (a, b) => a.lat === b.lat && a.lon === b.lon)}
      />
      <p className={styles.note}>The first place gets the full key; the others show their temperature beside it.</p>
    </>
  );
}

function StockSettings({ config }) {
  const byWeight = config.options.stock_size === STOCK_SIZE.WEIGHT;
  return (
    <>
      <ul className={styles.rows}>
        {config.stocks.map((s, i) => (
          <li key={s.symbol} className={styles.row}>
            <span className={styles.rowTicker}>{s.symbol}</span>
            <span className={styles.rowMain} />
            {byWeight && (
              <input
                type="number"
                min="0.1"
                step="0.5"
                className={styles.shortInput}
                value={s.weight ?? 1}
                onChange={(e) => editAt('stocks', i, { weight: Number(e.target.value) || 1 })}
                aria-label={`Weight for ${s.symbol}`}
              />
            )}
            <RemoveButton label={s.symbol} onClick={() => removeAt('stocks', i)} />
          </li>
        ))}
      </ul>
      <SearchAdd
        placeholder="Add a ticker — ASML, ^AEX, VWRL.AS…"
        search={searchSymbols}
        disabled={config.stocks.length >= stripLimit('stocks')}
        describe={(m) => `${m.symbol} · ${m.name || ''}${m.exchange ? ` · ${m.exchange}` : ''}`}
        onPick={(m) => addTo('stocks', { symbol: m.symbol, weight: 1 }, (a, b) => a.symbol === b.symbol)}
      />
      <div className={styles.field}>
        <span className={styles.fieldLabel}>Tile size</span>
        <SegmentedControl
          aria-label="Tile size"
          value={config.options.stock_size}
          onChange={(v) => setOption('stock_size', v)}
          options={[{ value: STOCK_SIZE.EQUAL, label: 'Equal' }, { value: STOCK_SIZE.WEIGHT, label: 'My weights' }]}
        />
      </div>
      <p className={styles.note}>Tiles are coloured by today&rsquo;s change. Quotes are delayed and refresh every minute.</p>
    </>
  );
}

function CryptoSettings({ config }) {
  const [symbol, setSymbol] = useState('');
  const add = (e) => {
    e.preventDefault();
    const s = symbol.trim().toUpperCase();
    if (/^[A-Z0-9]{2,10}$/.test(s)) update('crypto', (list) => (list.includes(s) || list.length >= stripLimit('crypto') ? list : [...list, s]));
    setSymbol('');
  };
  return (
    <>
      <ul className={styles.chips}>
        {config.crypto.map((c, i) => (
          <li key={c} className={styles.chipRow}>
            {c}
            <RemoveButton label={c} onClick={() => removeAt('crypto', i)} />
          </li>
        ))}
      </ul>
      <form className={styles.addForm} onSubmit={add}>
        <input className={styles.input} value={symbol} onChange={(e) => setSymbol(e.target.value)} placeholder="Add a coin — BTC, ETH, SOL…" aria-label="Coin symbol" />
        <Button type="submit" variant="secondary" disabled={!symbol.trim()}>Add</Button>
      </form>
      <div className={styles.field}>
        <span className={styles.fieldLabel}>Currency</span>
        <SegmentedControl
          aria-label="Currency"
          value={config.options.crypto_currency}
          onChange={(v) => setOption('crypto_currency', v)}
          options={CRYPTO_CURRENCIES.map((c) => ({ value: c, label: c }))}
        />
      </div>
    </>
  );
}

function NewsSettings({ config }) {
  const [url, setUrl] = useState('');
  const [label, setLabel] = useState('');
  const valid = /^https?:\/\/\S+$/i.test(url.trim());
  const add = (e) => {
    e.preventDefault();
    if (!valid) return;
    const u = url.trim();
    addTo('feeds', { url: u, label: label.trim() || new URL(u).hostname.replace(/^www\./, '') }, (a, b) => a.url === b.url);
    setUrl(''); setLabel('');
  };
  return (
    <>
      <ul className={styles.rows}>
        {config.feeds.map((f, i) => (
          <li key={f.url} className={styles.row}>
            <input
              className={styles.shortInput}
              value={f.label}
              maxLength={12}
              onChange={(e) => editAt('feeds', i, { label: e.target.value })}
              aria-label={`Label for ${f.url}`}
            />
            <span className={styles.rowMain} title={f.url}>{f.url.replace(/^https?:\/\//, '')}</span>
            <RemoveButton label={f.label} onClick={() => removeAt('feeds', i)} />
          </li>
        ))}
      </ul>
      <form className={styles.addForm} onSubmit={add}>
        <input className={styles.shortInput} value={label} onChange={(e) => setLabel(e.target.value)} placeholder="Label" maxLength={12} aria-label="Feed label" />
        <input className={styles.input} value={url} onChange={(e) => setUrl(e.target.value)} placeholder="RSS or Atom feed URL" aria-label="Feed URL" />
        <Button type="submit" variant="secondary" disabled={!valid || config.feeds.length >= stripLimit('feeds')}>Add</Button>
      </form>
    </>
  );
}

// Type-ahead that adds the picked result. `search` must be a stable function.
function SearchAdd({ placeholder, search, describe, onPick, disabled }) {
  const [query, setQuery] = useState('');
  const q = useDebounce(query.trim(), 250);
  const [found, setFound] = useState({ q: '', results: [] });

  useEffect(() => {
    if (!q) return undefined;
    let alive = true;
    search(q)
      .then((results) => { if (alive) setFound({ q, results: results || [] }); })
      .catch(() => { if (alive) setFound({ q, results: [] }); });
    return () => { alive = false; };
  }, [q, search]);

  const results = q && found.q === q ? found.results : [];
  return (
    <div className={styles.search}>
      <Icon name="magnifyingglass" size={12} className={styles.searchIcon} />
      <input
        className={styles.input}
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        placeholder={disabled ? 'List is full' : placeholder}
        disabled={disabled}
        aria-label={placeholder}
      />
      {results.length > 0 && (
        <ul className={styles.results}>
          {results.map((r, i) => (
            <li key={i}>
              <button type="button" onClick={() => { onPick(r); setQuery(''); }}>{describe(r)}</button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
