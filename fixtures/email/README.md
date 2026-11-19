# Email rendering fixtures

One real example email per rendering case the app has to handle, with its expected
outcome declared in [`manifest.json`](./manifest.json). This is the single source of
truth shared by every platform's test harness — they all render through the same
`@inbox2/email-body` engine, so a fixture that passes here is a guarantee for web,
desktop, iOS and Android at once.

## Who consumes this

| Harness | Location | Runs in | Covers |
|---|---|---|---|
| Engine fixtures | `packages/email-body/__tests__/fixtures.test.js` | vitest (jsdom) | `processBody()` over every case — quotes, signatures, `<pre>` unwrap, remote-content blocking |
| Web wrapper | `ui/web/src/components/MessageCard/__tests__/emailRendering.test.jsx` | vitest (jsdom) | `EmailFrame.buildSrcDoc` — CSP, FRAME_FIT_CSS, `<details>` collapse, `<style>` sanitization |
| Theme color rewrite | `ui/web/src/components/MessageCard/QuotedText.stories.jsx` | vitest (browser) | `QuotedText` dark/light luma rewrite (needs a real `<canvas>`) |
| Bundle drift guard | `packages/email-body/__tests__/bundleSync.test.js` | vitest (node) | the iOS/Android embedded `email-body.js` is byte-identical to a fresh build of `src/` |
| Native host contract | `packages/email-body/__tests__/nativeHostPage.test.js` | vitest (node) | the Swift/Kotlin WebView host pages still wire the bundle (CSP, collapse, height, proxy) — iOS↔Android parity |

Run them all: `cd ui/web && yarn test:email`

## Adding a rendering case

1. Drop the example email body as `cases/<name>.html` (the HTML the renderer receives,
   i.e. the message `body_html`).
2. Add an entry to `manifest.json` with the expected outcome.
3. `cd ui/web && yarn test:email` — the new case is picked up automatically; no code change.

### manifest entry

```json
{
  "name": "my-case",
  "file": "cases/my-case.html",
  "title": "Human-readable description",
  "source": "Where this email came from",
  "expect": {
    "hasQuote": false,
    "hasSignature": false,
    "blocksRemote": true,
    "unwrapsPre": false,
    "noOverflow":  true,
    "noShrink":    true,
    "contains":    ["data-blocked-src"],
    "notContains": [" srcset="]
  }
}
```

`noOverflow` is checked only by the native layout harnesses (iOS/Android), which render
the fixture through the real reader CSS in a WebView and assert it fits a phone viewport
— use it for fixed/min-width desktop emails that must reflow (e.g. Temu).

`noShrink` is also native-only: it asserts the scale-to-fit pass leaves the email at
scale ≈ 1 (full width). Use it for ordinary text emails — flowing prose or a plain-text
`white-space:pre-wrap` body — which must wrap to the column, never be scaled down to a
tiny strip.

All `expect` keys are optional (default `false` / empty). `contains` / `notContains` are
substring assertions against the `processBody()` output HTML. A universal invariant is
always checked: the output must never contain a live remote `src` (every one is
neutralized to a `data:` placeholder with the original stashed on `data-blocked-src`).

## Keeping native in sync

The native clients ship a built copy of the bundle. After changing
`packages/email-body/src`, run **`bin/sync-email-body`** to rebuild `dist/` and copy it
to `ui/ios/Resources/` and `ui/android/.../assets/`. `bundleSync.test.js` fails if you
forget.
