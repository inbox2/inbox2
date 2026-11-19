import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import Icon from '../Icon';
import api from '../../lib/api';
import { openLink } from '../../lib/openLink';
import useContainerSize from '../../hooks/useContainerSize';
import useCopyToClipboard from '../../hooks/useCopyToClipboard';
import useStripFeed from '../../hooks/useStripFeed';
import {
  STOCK_SIZE, localTimeZone, minutesInZone, dayPhase, relativeOffset, formatMinutes, workingSpans, sharedWindow,
  squarify, changeBucket, weightedChange, formatPrice, formatPct, tickerLabel, weatherIcon, rainSummary,
} from '../../lib/touchStrip';
import styles from './TouchStrip.module.css';

// The Touch Strip's keys. Each widget takes the strip config and renders either
// its compact key(s) or — `expanded` — the full-width Touch Bar-style takeover.
// Data comes through useStripFeed (cached per key, so compact ↔ expanded is instant).

const MIN = 60 * 1000;
const BAR_H = 37; // drawable height inside a key (strip 55px − padding)

function useNow(ms = 15 * 1000) {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    const t = setInterval(() => setNow(new Date()), ms);
    return () => clearInterval(t);
  }, [ms]);
  return now;
}

const dirClass = (pct) => (pct > 0 ? styles.up : pct < 0 ? styles.down : styles.dim);

function Spark({ values, width = 48, height = 22, pct }) {
  if (!values || values.length < 2) return null;
  const min = Math.min(...values);
  const span = Math.max(...values) - min || 1;
  const points = values
    .map((v, i) => `${((i / (values.length - 1)) * width).toFixed(1)},${(height - 1 - ((v - min) / span) * (height - 2)).toFixed(1)}`)
    .join(' ');
  return (
    <svg width={width} height={height} className={`${styles.spark} ${dirClass(pct)}`} aria-hidden="true">
      <polyline points={points} />
    </svg>
  );
}

const Loading = () => <span className={styles.sub}>Loading…</span>;

// ── World clocks ─────────────────────────────────────────────────────────────

export function Clocks({ config, expanded, onExpand }) {
  const now = useNow();
  const base = localTimeZone();
  if (!config.clocks.length) return null;
  if (expanded) return <ClockPlanner clocks={config.clocks} base={base} now={now} />;

  return (
    <button type="button" className={styles.key} onClick={onExpand} title="World clocks — open the meeting planner">
      {config.clocks.map((c) => {
        const mins = minutesInZone(c.tz, now);
        const phase = dayPhase(mins);
        return (
          <span key={`${c.tz}-${c.label}`} className={styles.clock} title={`${c.tz.replace(/_/g, ' ')} · ${phase}`}>
            <span className={styles.clockTop}>
              <span className={styles.label}>{c.label}</span>
              <span className={styles.value}>{formatMinutes(mins)}</span>
              <span className={styles.sub}>{relativeOffset(c.tz, base, now)}</span>
            </span>
            <svg className={styles.dayBand} viewBox="0 0 96 4" preserveAspectRatio="none" aria-hidden="true">
              <rect width="96" height="4" rx="2" className={styles[phase]} />
              <rect x={(mins / 1440) * 96 - 0.8} width="1.6" height="4" className={styles.dayMark} />
            </svg>
          </span>
        );
      })}
    </button>
  );
}

const LABEL_W = 84;

// Each city's 09–17 on your local 24h axis, the now-line, and the longest
// stretch where everyone is working.
function ClockPlanner({ clocks, base, now }) {
  const ref = useRef(null);
  const { width } = useContainerSize(ref, { width: 800, height: BAR_H });
  const n = clocks.length;
  const gap = 2;
  const laneH = Math.max(3, (BAR_H - gap * (n - 1)) / n);
  const labelled = n <= 4;
  const axisW = Math.max(width - (labelled ? LABEL_W : 0), 1);
  const x = (m) => (labelled ? LABEL_W : 0) + (m / 1440) * axisW;
  const tzs = [...new Set([base, ...clocks.map((c) => c.tz)])];
  const shared = sharedWindow(tzs, base, now);
  const nowX = x(minutesInZone(base, now));

  return (
    <>
      <div ref={ref} className={`${styles.key} ${styles.grow} ${styles.canvasKey}`}>
        <svg width={width} height={BAR_H} role="img" aria-label="Working hours per city on your local day">
          {clocks.map((c, i) => {
            const y = i * (laneH + gap);
            return (
              <g key={`${c.tz}-${c.label}`}>
                <title>{`${c.label} ${formatMinutes(minutesInZone(c.tz, now))} — works 09:00–17:00`}</title>
                {labelled && (
                  <text x="0" y={y + laneH / 2 + 3} className={styles.laneText}>
                    {`${c.label} ${formatMinutes(minutesInZone(c.tz, now))}`}
                  </text>
                )}
                <rect x={x(0)} y={y} width={axisW} height={laneH} rx={laneH / 2} className={styles.laneTrack} />
                {workingSpans(c.tz, base, now).map(([s, e]) => (
                  <rect key={s} x={x(s)} y={y} width={x(e) - x(s)} height={laneH} rx={laneH / 2} className={styles.laneWork} />
                ))}
              </g>
            );
          })}
          {shared && <rect x={x(shared[0])} width={x(shared[1]) - x(shared[0])} height={BAR_H} rx="3" className={styles.laneShared} />}
          <rect x={nowX - 1} width="2" height={BAR_H} rx="1" className={styles.nowLine} />
        </svg>
      </div>
      <div className={styles.key}>
        <span className={styles.chip}>Overlap</span>
        <span className={styles.value}>{shared ? `${formatMinutes(shared[0])} – ${formatMinutes(shared[1])}` : 'None today'}</span>
      </div>
    </>
  );
}

// ── Weather ──────────────────────────────────────────────────────────────────

function usePlaceWeather(place) {
  const key = place.current ? 'weather:here' : `weather:${place.lat},${place.lon}`;
  return useStripFeed(
    key,
    () => api.stripWeather(place.current ? {} : { lat: place.lat, lon: place.lon, place: place.label }).then((r) => r.forecast),
    10 * MIN,
  );
}

const placeName = (place, f) => place.label || f?.place || 'Here';

function RainBars({ rain, count, height = 18 }) {
  const slots = (rain || []).slice(0, count);
  if (!slots.length) return null;
  return (
    <svg width={slots.length * 4} height={height} className={styles.rain} aria-hidden="true">
      {slots.map((r, i) => {
        const h = r.mm < 0.05 ? 1 : Math.min(height, 2 + Math.sqrt(r.mm) * 10);
        return <rect key={r.time} x={i * 4} y={height - h} width="3" height={h} rx="1" />;
      })}
    </svg>
  );
}

function WeatherMain({ place }) {
  const f = usePlaceWeather(place);
  if (!f) return <Loading />;
  return (
    <>
      <Icon name={weatherIcon(f.code, f.is_day)} size={22} className={styles.weatherIcon} />
      <span className={styles.big}>{`${f.temp_c}°`}</span>
      <span className={styles.stack}>
        <span className={styles.label}>{placeName(place, f)}</span>
        <span className={styles.sub}>{`${f.low_c}° – ${f.high_c}°`}</span>
      </span>
      <span className={styles.stack} title={rainSummary(f.rain) || ''}>
        <RainBars rain={f.rain} count={8} />
        <span className={styles.micro}>rain · 2h</span>
      </span>
    </>
  );
}

function WeatherMini({ place }) {
  const f = usePlaceWeather(place);
  return (
    <span className={styles.inline}>
      <span className={styles.label}>{placeName(place, f)}</span>
      <span className={styles.value}>{f ? `${f.temp_c}°` : '—'}</span>
    </span>
  );
}

function WeatherDetail({ place }) {
  const f = usePlaceWeather(place);
  if (!f) return <div className={styles.key}><Loading /></div>;
  return (
    <>
      <div className={styles.key}>
        <Icon name="location" size={12} className={styles.accentText} />
        <span className={styles.value}>{placeName(place, f)}</span>
        <Icon name={weatherIcon(f.code, f.is_day)} size={16} className={styles.weatherIcon} />
        <span className={styles.big}>{`${f.temp_c}°`}</span>
      </div>
      <div className={`${styles.key} ${styles.grow} ${styles.spread}`}>
        {f.hourly.map((h) => (
          <span key={h.time} className={styles.inline} title={h.time.replace('T', ' ')}>
            <span className={styles.sub}>{h.time.slice(11, 13)}</span>
            <Icon name={weatherIcon(h.code, true)} size={12} className={styles.weatherIcon} />
            <span className={styles.value}>{`${h.temp_c}°`}</span>
          </span>
        ))}
      </div>
      <div className={styles.key}>
        <RainBars rain={f.rain} count={16} height={28} />
        <span className={styles.stack}>
          <span className={styles.value}>{rainSummary(f.rain)}</span>
          <span className={styles.sub}>next 4 hours</span>
        </span>
      </div>
    </>
  );
}

export function Weather({ config, expanded, onExpand }) {
  const [first, ...rest] = config.places;
  if (!first) return null;
  if (expanded) {
    return (
      <>
        <WeatherDetail place={first} />
        {rest.map((p) => <div key={`${p.lat},${p.lon}`} className={styles.key}><WeatherMini place={p} /></div>)}
      </>
    );
  }
  return (
    <button type="button" className={styles.key} onClick={onExpand} title="Weather — next 12 hours">
      <WeatherMain place={first} />
      {rest.map((p) => <WeatherMini key={p.current ? 'here' : `${p.lat},${p.lon}`} place={p} />)}
    </button>
  );
}

// ── Stocks ───────────────────────────────────────────────────────────────────

function useQuotes(symbols) {
  return useStripFeed(
    symbols.length ? `quotes:${symbols.join(',')}` : null,
    () => api.stripQuotes(symbols).then((r) => r.quotes),
    MIN,
  ) || [];
}

// Size = weight (equal or the user's), colour = day change. Labels appear only
// where the tile has room; the full line is in the tooltip.
function Treemap({ quotes, weightOf, width: fixedWidth, detailed }) {
  const ref = useRef(null);
  const { width: measured } = useContainerSize(ref, { width: fixedWidth || 600, height: BAR_H });
  const W = fixedWidth || measured;
  const cells = squarify(quotes.map((q) => ({ ...q, value: weightOf(q.symbol) })), W, BAR_H);

  return (
    <span ref={ref} className={fixedWidth ? styles.treemap : `${styles.treemap} ${styles.grow}`}>
      <svg width={W} height={BAR_H} role="img" aria-label="Watchlist treemap">
        {cells.map((c) => {
          const label = tickerLabel(c.symbol);
          const pct = formatPct(c.change_pct);
          const fitsLabel = c.w >= label.length * 7 + 8;
          const twoLines = c.h >= 26 && c.w >= 40;
          const oneLinePct = !twoLines && c.w >= label.length * 7 + 58;
          const price = detailed && c.w >= label.length * 7 + 124;
          return (
            <g key={c.symbol} transform={`translate(${c.x} ${c.y})`}>
              <title>{`${c.name || c.symbol} (${c.symbol}) · ${formatPrice(c.price)} ${c.currency || ''} · ${pct}`}</title>
              <rect width={Math.max(c.w - 1, 0)} height={Math.max(c.h - 1, 0)} className={styles[changeBucket(c.change_pct)]} />
              {fitsLabel && (
                <text x="5" y={twoLines ? 14 : c.h / 2 + 4} className={styles.tileText}>
                  <tspan className={styles.tileTicker}>{label}</tspan>
                  {oneLinePct && <tspan dx="5">{pct}</tspan>}
                  {oneLinePct && price && <tspan dx="5" className={styles.tileDim}>{formatPrice(c.price)}</tspan>}
                </text>
              )}
              {twoLines && (
                <text x="5" y="28" className={styles.tileText}>
                  {pct}
                  {price && <tspan dx="5" className={styles.tileDim}>{formatPrice(c.price)}</tspan>}
                </text>
              )}
            </g>
          );
        })}
      </svg>
    </span>
  );
}

export function Stocks({ config, expanded, onExpand }) {
  const quotes = useQuotes(config.stocks.map((s) => s.symbol));
  if (!config.stocks.length) return null;
  const byWeight = config.options.stock_size === STOCK_SIZE.WEIGHT;
  const weights = Object.fromEntries(config.stocks.map((s) => [s.symbol.toUpperCase(), byWeight ? Math.max(Number(s.weight) || 1, 0.1) : 1]));
  const weightOf = (symbol) => weights[symbol.toUpperCase()] ?? 1;
  const avg = weightedChange(quotes, weightOf);
  const summary = (
    <span className={styles.stack}>
      <span className={styles.label}>{expanded ? `Watchlist · ${quotes.length}` : 'Watch'}</span>
      <span className={`${styles.value} ${dirClass(avg)}`}>{quotes.length ? formatPct(avg) : '—'}</span>
    </span>
  );

  if (expanded) {
    return (
      <>
        <div className={styles.key}>{summary}</div>
        <div className={`${styles.key} ${styles.grow} ${styles.mapKey}`}>
          <Treemap quotes={quotes} weightOf={weightOf} detailed />
        </div>
      </>
    );
  }
  return (
    <button type="button" className={`${styles.key} ${styles.mapKey}`} onClick={onExpand} title="Stocks — open the full treemap">
      {summary}
      {quotes.length ? <Treemap quotes={quotes} weightOf={weightOf} width={300} /> : <Loading />}
    </button>
  );
}

// ── Crypto (Yahoo pairs, e.g. BTC-EUR) ───────────────────────────────────────

function CoinMain({ q }) {
  return (
    <span className={styles.stack}>
      <span className={styles.inline}>
        <span className={styles.label}>{tickerLabel(q.symbol)}</span>
        <span className={`${styles.micro} ${dirClass(q.change_pct)}`}>{formatPct(q.change_pct)}</span>
      </span>
      <span className={styles.value}>{formatPrice(q.price)}</span>
    </span>
  );
}

export function Crypto({ config, expanded, onExpand }) {
  const currency = config.options.crypto_currency || 'EUR';
  const quotes = useQuotes(config.crypto.map((c) => `${c}-${currency}`));
  if (!config.crypto.length) return null;

  if (expanded) {
    return quotes.map((q) => (
      <div key={q.symbol} className={`${styles.key} ${styles.grow} ${styles.between}`} title={`${q.name || q.symbol} · ${currency}`}>
        <CoinMain q={q} />
        <Spark values={q.spark} width={80} height={26} pct={q.change_pct} />
      </div>
    ));
  }

  const [lead, ...rest] = quotes;
  return (
    <button type="button" className={styles.key} onClick={onExpand} title={`Crypto in ${currency} — show every coin`}>
      {lead ? (
        <>
          <CoinMain q={lead} />
          <Spark values={lead.spark} pct={lead.change_pct} />
        </>
      ) : <Loading />}
      {rest.length > 0 && (
        <span className={styles.coinList}>
          {rest.slice(0, 2).map((q) => (
            <span key={q.symbol} className={styles.coinRow}>
              <span className={styles.label}>{tickerLabel(q.symbol)}</span>
              <span>{formatPrice(q.price)}</span>
              <span className={dirClass(q.change_pct)}>{formatPct(q.change_pct)}</span>
            </span>
          ))}
        </span>
      )}
    </button>
  );
}

// ── News ─────────────────────────────────────────────────────────────────────

const ROTATE_MS = 8000;
const MARQUEE_PX_PER_S = 60;

function useHeadlines(feeds) {
  const urls = feeds.map((f) => f.url);
  return useStripFeed(
    urls.length ? `news:${urls.join('|')}` : null,
    () => api.stripNews(urls).then((r) => r.headlines),
    10 * MIN,
  ) || [];
}

const feedLabel = (feeds, h) => feeds.find((f) => f.url === h.feed)?.label || h.source;

export function News({ config, expanded, onExpand }) {
  const items = useHeadlines(config.feeds);
  const [index, setIndex] = useState(0);
  const [paused, setPaused] = useState(false);
  const count = items.length;

  useEffect(() => {
    if (expanded || paused || count < 2) return undefined;
    const t = setInterval(() => setIndex((i) => (i + 1) % count), ROTATE_MS);
    return () => clearInterval(t);
  }, [expanded, paused, count]);

  if (!config.feeds.length) return null;
  if (expanded) return <NewsTicker items={items} feeds={config.feeds} />;

  const h = items[index % Math.max(count, 1)];
  return (
    <div className={`${styles.key} ${styles.grow} ${styles.newsKey}`} role="presentation" onMouseEnter={() => setPaused(true)} onMouseLeave={() => setPaused(false)}>
      <button type="button" className={styles.chip} onClick={onExpand} title="News — open the ticker">
        {h ? feedLabel(config.feeds, h) : 'News'}
      </button>
      {h ? (
        <button type="button" className={styles.headline} onClick={() => openLink(h.url)} title={h.title}>
          {h.title}
        </button>
      ) : <Loading />}
      {count > 0 && <span className={styles.sub}>{`${(index % count) + 1}/${count}`}</span>}
      <button type="button" className={styles.iconButton} onClick={() => setIndex((i) => i + 1)} aria-label="Next headline" disabled={count < 2}>
        <Icon name="chevron.right" size={10} />
      </button>
    </div>
  );
}

function NewsTicker({ items, feeds }) {
  const [source, setSource] = useState(null);
  const trackRef = useRef(null);
  const shown = source ? items.filter((h) => h.feed === source) : items;

  // Constant reading speed whatever the length: the duration follows the width.
  useLayoutEffect(() => {
    const el = trackRef.current;
    if (el) el.style.setProperty('--marquee-duration', `${Math.max(el.scrollWidth / 2 / MARQUEE_PX_PER_S, 10)}s`);
  }, [shown]);

  // Twice over, so the -50% loop is seamless.
  const loop = [...shown, ...shown];
  return (
    <>
      <div className={styles.key}>
        <button type="button" className={styles.filter} aria-pressed={!source} onClick={() => setSource(null)}>All</button>
        {feeds.map((f) => (
          <button key={f.url} type="button" className={styles.filter} aria-pressed={source === f.url} onClick={() => setSource(f.url)}>
            {f.label || new URL(f.url).hostname}
          </button>
        ))}
      </div>
      <div className={`${styles.key} ${styles.grow} ${styles.marquee}`}>
        <div ref={trackRef} className={styles.track}>
          {loop.map((h, i) => (
            <button key={`${h.url}-${i}`} type="button" className={styles.tickerItem} onClick={() => openLink(h.url)} tabIndex={i < shown.length ? 0 : -1}>
              <span className={styles.chipText}>{feedLabel(feeds, h)}</span>
              {h.title}
            </button>
          ))}
        </div>
      </div>
    </>
  );
}

// ── Public IP ────────────────────────────────────────────────────────────────

export function Ip() {
  const info = useStripFeed('ip', () => api.stripIp().then((r) => r.ip), 10 * MIN);
  const [copied, copy] = useCopyToClipboard(1500);
  const detail = [info?.country_code, info?.proxy ? 'VPN / proxy' : info?.isp].filter(Boolean).join(' · ');
  return (
    <button type="button" className={styles.key} onClick={() => info && copy(info.ip)} title={`${info?.ip || 'Public IP'} — click to copy`}>
      <Icon name={info?.proxy ? 'checkmark.shield.fill' : 'checkmark.shield'} size={14} className={info?.proxy ? styles.accentText : styles.dim} />
      <span className={styles.stack}>
        <span className={`${styles.mono} ${styles.ipText}`}>{copied ? 'Copied' : info?.ip || '—'}</span>
        {detail && <span className={styles.sub}>{detail}</span>}
      </span>
    </button>
  );
}
