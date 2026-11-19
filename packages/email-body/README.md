# @inbox2/email-body

Framework-free email body processing — **quote/signature collapsing** and
**remote-image privacy** — with no dependency on React, the app, or any framework.
It needs only the browser DOM it runs in, so the exact same code drives:

- the **web app**'s desktop email iframe (`ui/web`, via a Vite alias), and
- the native **iOS / Android WebViews** (bundled as a single file and injected),

…which means every platform collapses quotes, detects signatures, and blocks
remote images **identically** — this package is the single source of truth.

## API

```js
import {
  detectQuotes,        // (html) -> { content, hasQuote }   marks data-quoted-block
  detectSignatures,    // (html) -> { content, hasSignature } marks data-signature-block
  blockRemoteContent,  // (domRoot) -> number   neutralizes remote refs in place
  PLACEHOLDER, BLOCKED_TAGS, BLOCKED_ATTR,
  shouldProxyImages,   // (flags) -> boolean   pure remote-image privacy decision
  processBody,         // (html, {block?}) -> { html, hasQuote, hasSignature, blockedCount }
} from '@inbox2/email-body';
```

The detectors return **marked HTML**; the host decides how to render the marked
blocks (the web iframe wraps them in `<details>`; React extracts them into
independent `···` toggles). `shouldProxyImages` is the pure policy — the host
supplies the trust-list / preference / token lookups and performs the actual
proxy fetch + DOM swap.

## Build (for the mobile WebViews)

```sh
npm run build   # esbuild → dist/email-body.js (IIFE, global Inbox2EmailBody)
```

## Test

The parity-guard tests run under the web app's vitest:

```sh
cd ../../ui/web && yarn vitest run --project unit
```
