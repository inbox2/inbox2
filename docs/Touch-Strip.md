# Touch Strip

The app-wide bottom bar: glanceable world clocks, weather, a stock treemap, crypto prices, news headlines and your public IP. It borrows the MacBook Touch Bar's structure (a row of keys, tap one for its full-width view). The look is the Spaces dashboard's stat panel, not the Touch Bar's raised keys:
- one 55px translucent panel with a hairline top border;
- flat key segments split by hairline dividers — no bevels or shadows;
- icon buttons in bordered wells.

The Aero chrome-glass look was tried on 2026-09-29 and rejected. Design canvas: the "inbox2 Touch Strip" artifact (it shows the original raised-key exploration).

## Where it lives

- **Web / desktop** (same React code): `ui/web/src/components/TouchStrip/`
  - `TouchStrip.jsx` is the shell: mode, the expanded takeover, and the customize button.
  - `StripWidgets.jsx` holds one component per widget. Each renders compact keys, or the full-width view when `expanded`.
  - `StripCustomize.jsx` is the customize sheet.
  - `TouchStrip.module.css` holds the styles.
- **iPad** (SwiftUI port): `ui/ios/Sources/TouchStrip/` — `TouchStripMath.swift` (the pure maths, tested in `Tests/TouchStripMathTests.swift`), `TouchStripModel.swift` (feeds, layout sync, mode), `TouchStripWidgets.swift`, `TouchStripView.swift`, `TouchStripCustomize.swift`. Mounted under `IPadShell` with `.safeAreaInset(edge: .bottom)`; pinned or hidden (`ipad.touchStrip`), hidden while the on-screen keyboard is up. The same `account/touch-strip` layout; the device copy is tied to the account that saved it, so a second account starts from the defaults. A failed feed retries after 15 s.
- It is mounted at the bottom of each app shell: `AppChrome` (explorer, search, spaces, calendar…), `UnifiedInboxView` and `InboxPage`. It is not on settings or console pages.
- **Mode**: pinned, floating or hidden via `usePaneMode` (`TOUCH_STRIP_MODE`, per device), the same Rider-style picker as the calendar rail and reading pane.
  - **Pinned** sits in the layout flow.
  - **Floating** hovers above a 20px edge tab and auto-hides like the Dock. Resting on the edge opens it after 120ms; leaving the dock closes it after 450ms (kept open while the customize sheet is up). Clicking the tab pins it open instead.
  - **Hidden** collapses to that tab.
- `--touch-strip-offset` (set on `<html>` from the dock's measured height) lifts `DraftBar` and `UndoToast` off the strip.

## Widgets

| id | Compact key | Tap → full width |
|---|---|---|
| `clocks` | City code, time, offset from you, and a band coloured by the city's current phase (night/dawn/day/dusk, `dayPhase` — fixed hours, since a clock knows its zone, not its latitude) with a time-of-day mark | **Meeting planner**: each city's 09–17 on your local axis, the now-line, and the longest window where everyone works |
| `weather` | Icon, temperature, today's low–high, the next 2h of rain as 15-min bars. Extra places show their temperature beside it | 12 hours, 4h rain bars, and "Rain from 15:10" / "Dry for 4h" |
| `stocks` | Weighted day change + a squarified **treemap**: size = weight (equal or yours), colour = day-change step (3 up, 3 down, flat) from the strip's own market palette (`--strip-up1…3` / `--strip-down1…3`), not the theme accents — some themes mute those to grey. Labels only where they fit; the full line is in the tooltip | Full-width treemap with prices |
| `crypto` | Lead coin with a 24h sparkline, two more stacked | Every coin with a sparkline |
| `news` | Rotating headline (8s, pauses on hover), your feed label, counter, next | Scrolling ticker (constant 60px/s, pauses on hover/focus, no animation under reduced-motion) with a per-feed filter |
| `ip` | Public IP, country, ISP or "VPN / proxy". Click copies | — |

The customize sheet's palette tiles render each widget's real compact key (`widgetMap.js`, `inert`) as a live preview with an on/off switch; the bottom "Order" row is content-sized chips you drag to reorder.

The pure maths lives in `lib/touchStrip.js` and is covered by `lib/__tests__/touchStrip.test.js`: squarify, change buckets, DST-correct zone offsets via `Intl`, working spans and the shared window, WMO code → icon, the rain summary. The treemap, sparklines, lanes and bands are SVG, so dynamic geometry never needs inline styles (F1).

## Data: `GET /api/v1/strip/*` (Rails, public)

`StripController` + `StripFeeds` + `StripSerializers`. These endpoints are **public**, like `WeatherController`. They expose no tenant data, and the standalone desktop has no API session. Rack::Attack throttles them per IP: 120/min overall, 20/min for `news`. Every upstream is cached server-side, so a thousand strips polling AAPL cost one upstream call a minute. Failures aren't cached (`skip_nil`) and never raise.

| Endpoint | Upstream (no keys) | Cache |
|---|---|---|
| `quotes?symbols=AAPL,ASML.AS,BTC-EUR` | Yahoo Finance `v8/finance/chart`. Also serves crypto: the client asks for `BTC-EUR` | 60s per symbol |
| `symbols?q=` | Yahoo `v1/finance/search` | 1 day |
| `places?q=` | Open-Meteo geocoding (returns the IANA zone, which the clocks use) | 1 day |
| `weather?lat=&lon=&place=` (no coords → caller's IP) | Open-Meteo forecast (current, hourly, daily, `minutely_15` rain) | 10 min per 0.01° |
| `ip` | `CF-Connecting-IP`, else `remote_ip`, then ip-api.com (country, ISP, `proxy` flag). Coordinates are never returned | 1h per IP |
| `news?feeds[]=` | The user's RSS/Atom URLs, fetched through `PrivateAddressGuard.pinned_url` on every redirect hop (SSRF + DNS-rebinding), 2MB cap, Nokogiri with `NONET` and no `NOENT` (no XXE), http(s) links only | 10 min per feed |

**Yahoo is unofficial.** It can change or block without notice (it already 403s Ruby's default UA, hence `StripFeeds::USER_AGENT`). If it breaks, `StripFeeds.quote` is the one place to swap in Finnhub or Twelve Data (both need a key). CoinGecko was the first crypto choice; its `/coins/markets` 403'd from here, and Yahoo pairs made it unnecessary.

Client polling (`hooks/useStripFeed.js`): a module-level cache per key, so compact ↔ expanded and shell changes repaint instantly. Polling pauses while the window is hidden. Intervals: quotes 1 min; weather, news and IP 10 min.

## Layout sync: `users.touch_strip` (jsonb)

`GET/PUT /api/v1/account/touch-strip` (authenticated). Sections: `items` (order = strip order, must be in `User::TOUCH_STRIP_ITEMS`), `clocks [{label,tz}]`, `places [{label,lat,lon} | {current:true}]`, `stocks [{symbol,weight}]`, `crypto ["BTC",…]`, `feeds [{url,label}]`, `options {stock_size, crypto_currency}`. Strong params allow-list the shape. The model caps it at 16KB and rejects unknown widgets. A never-saved section serializes as null and the client fills in its default (`mergeConfig`).

Client (`lib/touchStrip.js`): `localStorage` paints first, which also serves the standalone desktop with no account. Once signed in, the account copy is loaded. If the account never saved a strip, it adopts this device's layout instead of resetting it. Edits save locally at once and to the account with an 800ms debounce.

Migration: `20260929000001_add_touch_strip_to_users` (also folded into the initial schema + `schema.rb`).

## Not built (yet)

- **Market-cap tile sizing and week-change colouring** were in the design; the chart endpoint has neither market cap nor a cheap week delta. Sizes are Equal / My weights; colour is the day change.
- **Drag from the palette into the strip**: the palette uses on/off switches. Reordering is drag (dnd-kit, keyboard too) in the sheet's Order row.
- **GPS location**: "current location" is IP-based (no permission prompt; a VPN moves it).
- Custom working hours in the planner (fixed 09–17), and native iOS/Android strips.
