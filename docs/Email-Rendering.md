# Email Rendering

How inbox2 renders received email bodies — the two render paths (HTML vs
plain-text), sanitization, the sandboxed iframe + CSP, remote-image blocking and
proxying, and quote/signature collapsing.

The guiding principle: **opening a message must not phone home.** Remote content
(images, CSS, fonts, SVG, media) is a tracking vector — loading any of it leaks
the reader's IP, User-Agent and open time to the sender. So nothing remote loads
until we either proxy it server-side (hiding the reader) or the user explicitly
asks for a direct load. The reference threat model is
[emailprivacytester.com](https://www.emailprivacytester.com) (≈60 techniques).

---

## 1. Entry point and the two paths

`ConversationDetail.jsx` renders one `<MessageCard>` per message:

```jsx
<MessageCard
  body={msg.body_html || linkifyText(msg.body_plain) || ''}
  isHtml={!!msg.body_html}
  sender={...} email={senderEmail(...)} ... />
```

`MessageCard` branches on `isHtml`:

| Path | Condition | Renderer | Why |
|------|-----------|----------|-----|
| **HTML** | `msg.body_html` present | `EmailFrame` (sandboxed iframe) | full CSS/layout fidelity, isolated from the app |
| **Plain-text** | only `body_plain` | `QuotedText` inline (`dangerouslySetInnerHTML`) | no images/layout; render inline so it adapts to the app theme |

Plain-text bodies are converted to HTML by `lib/linkifyText.js` (escape, wrap
bare `http(s)`/`www` URLs in `<a>`, `\n` → `<br>`) so their links are clickable.

`PreviewPane` (ComposePopup) is **not** part of this — it renders the user's own
outgoing draft, so it only sanitizes and never blocks/proxies.

---

## 2. HTML path — `components/MessageCard/EmailFrame.jsx`

HTML email renders inside a **sandboxed `<iframe srcdoc>`** — the same approach
Gmail/Apple Mail/Outlook use. The iframe is `sandbox="allow-same-origin"` (so the
parent can drive its document) but has **no `allow-scripts`**, so email
JavaScript never runs. It's the durable isolation boundary: the email's `<style>`
and layout render faithfully while being completely walled off from the app.

### 2.1 `buildSrcDoc(html, allowRemote)` pipeline

1. **Sanitize** — `DOMPurify.sanitize(html, { FORBID_TAGS: BLOCKED_TAGS, FORBID_ATTR: BLOCKED_ATTR })`.
   Keeps `<style>` and layout (tables, divs, spans), strips `<script>`, event
   handlers, and the remote-fetch / bypass tags (`iframe, object, embed, applet,
   portal, bgsound, video, audio, source, track, base, form, input, button,
   link, meta, frame, frameset, param`).
2. **Sanitize stylesheets** — `sanitizeStyleSheets()` removes `@import` and
   rewrites remote `url(...)` → `none` inside every `<style>` block. We can't
   proxy a CSS-rule background (no element to attach a blob to), so those are
   neutralized for privacy. (Inline `background-image` *is* proxied — see §3.)
3. **Block remote content** — `blockRemoteContent(doc.body)` neutralizes every
   image vector into `data-blocked-*` placeholders (§3).
4. **Detect + collapse quotes/signatures** — `detectQuotes` and
   `detectSignatures` wrap their blocks in `[data-quoted-block]` /
   `[data-signature-block]`; `collapseBlocks()` turns each into a native
   `<details>` (§4).
5. **Assemble the document** — `<!doctype html>` + `<head>` containing the **CSP
   meta** (§2.3), `viewport`, `x-dns-prefetch-control: off`, and `BASE_CSS` +
   `<body>` with the processed HTML.

`srcDoc` is memoized on `[html, directNoKey]` (the CSP relaxes only in the no-key
direct case — §2.3, §3).

### 2.2 Iframe wiring (`handleLoad`, runs on each (re)load)

Because the iframe is same-origin, the parent does everything from
`iframe.contentDocument`:

- **Image proxy** — `useRemoteImages(docBody, html, sender)` traverses the iframe
  document (§3). Parent-created `blob:` URLs load inside it because it shares the
  parent origin.
- **Link interception** — a `click` listener on the document calls `openLink`
  (in-app browser tab vs system browser; ⌘/Ctrl-click = external). Email has no
  scripts, so default navigation is otherwise inert.
- **Height** — the iframe is sized to `cdoc.body.scrollHeight` (NOT
  `documentElement.scrollHeight`: once we set the iframe tall, `<html>` fills that
  viewport and its `scrollHeight` stays inflated and never shrinks). A
  `ResizeObserver` on the body re-sizes as proxied images load. No inner
  scrollbars.
- **Background heuristic** (`applyBackground`) — emails assume a white page, but
  many are dark-text-on-nothing (need white to read) while marketing emails paint
  their own background. We sample the painted background behind the content at a
  few points; if ≥2 are covered by an opaque colour/image, the page goes
  **transparent** (the app's dark surface shows through the margins) with `padding:
  0`; otherwise it stays **white** with `padding: 16px` so text isn't cramped.

### 2.3 Content-Security-Policy (the hard backstop)

A `<meta http-equiv="Content-Security-Policy">` inside the srcdoc is the
defense-in-depth that makes leaks structurally impossible — even for a vector
`blockRemoteContent` might miss, the browser refuses the request.

- **With a token (default, strict):**
  `default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'; font-src data:; media-src 'none'`
  Only inline `data:` and our proxied `blob:` images render. Every remote
  load — SVG, CSS-escape, newline-src, duplicate-src, web fonts, media — is
  blocked at the browser level. Inline `<style>`/`style=""` still work
  (`'unsafe-inline'`), so layout is intact.
- **No token, explicit direct load (relaxed):** when the user clicks "Show
  images" and there is no key for the proxy, `img-src`/`font-src` are relaxed to
  allow `https:`/`http:` so the chosen images load directly. This is the only
  path that loads remote content into the reader's webview, and only on explicit
  action with no private alternative available.

---

## 3. Remote images: blocking + proxying

### 3.1 `lib/blockRemoteContent.js`

Runs over a parsed DOM root and neutralizes in place, returning the count of
restorable images (the banner total). For each vector it **stashes** the original
URL on a `data-*` attribute and swaps in a transparent 1×1 placeholder, so the
loader can later restore or proxy it:

| Vector | Handling |
|--------|----------|
| `<img src>`, `<input type=image>` | → `data-blocked-src`, src = placeholder |
| `srcset` (img / picture / video source) | → `data-blocked-srcset`, removed |
| `<video poster>` | → `data-blocked-poster`, removed |
| legacy `background=""` attr (body/td/table) | → `data-blocked-bg`, removed |
| inline `style="background-image:url()"` / `background:url()` | → `data-blocked-bg`, `background-image: none` |
| SVG `<image>` / `<use>` / `<feImage>` `href` / `xlink:href` | **stripped** (proxying SVG refs isn't worth it) |
| inline `list-style-image` / `cursor` / `content` url() | stripped |

`BLOCKED_TAGS` / `BLOCKED_ATTR` are exported here and fed to DOMPurify (§2.1).

### 3.2 `hooks/useRemoteImages.js`

Drives loading of the neutralized images, operating on a DOM root (the iframe
body). State per message via `shownFor === body` comparison (so a new message
resets cleanly without setState-in-render/effect).

Decision per image:

```
hasToken   = api.token || localStorage.inbox2_token
canProxy   = imageProxy-pref enabled && hasToken      // auto-load on open
forceDirect = shown-this-msg || isSafeSender || alwaysShowImages

if (canProxy || (forceDirect && hasToken))  → proxy via blob   (private)
else if (forceDirect)                        → direct load      (no key; needs relaxed CSP)
else                                         → stay blocked, show banner
```

- **Proxy load** (`loadViaProxy`): `api.fetchProxiedImage(url)` → `Blob` →
  `URL.createObjectURL` → set as `src` or `style.backgroundImage`. Object URLs are
  revoked on cleanup. `data-proxyTried` prevents re-fetching on re-scan.
- A `MutationObserver` re-scans so images revealed late (expanding a `<details>`
  quote/signature) get the same treatment.
- `directNoKey` (= `forceDirect && !hasToken`) is returned so `EmailFrame` can
  relax the CSP for that one case.

### 3.3 The banner — `components/RemoteContentBanner`

Shown above the body when `blockedCount > 0 && !forceDirect && !canProxy` (proxy
off / no key and not yet shown). It's a **split button**:

- **Show images** (primary) → `onShowOnce` (this message only).
- Dropdown (reuses `DropdownMenu`):
  - **Show images once**
  - **Always show from this sender** → `safeSenders` (`lib/safeSenders.js`,
    persisted set of addresses)
  - **Always show images** → `alwaysShowImagesPref` (global flag)

With a key these all load via the proxy; without one, directly.

### 3.4 Backend proxy — `api/app/controllers/api/v1/image_proxy_controller.rb`

`GET /api/v1/image-proxy?url=<encoded>` — user-scoped, returns raw image bytes
(a deliberate exception to the Alba-only rule, like the raw-message endpoint).

- **Auth**: standard bearer — web **session** token *or* a personal **API key**
  (`ink_…`), via `ApplicationController#authenticate_user` (Session, then
  `ApiKey.authenticate`). The client fetches with `fetch()` so the token rides in
  the `Authorization` header, never the URL. Standalone desktop clients (no web
  session) paste an API key in Settings → Privacy.
- **SSRF guard**: `app/services/private_address_guard.rb` — only public IPs;
  rejects loopback/RFC1918/CGNAT/link-local (incl. cloud metadata)/ULA/multicast,
  re-validated on every redirect hop.
- **Limits**: no cookies, ≤3 redirects, 10s timeout, 10 MB cap, image-only
  `Content-Type` (else 415).
- **Identity**: User-Agent `inbox2-image-proxy/1.0 (+https://inbox2.com/bot)` —
  documented publicly at `website/bot.html` (→ https://inbox2.com/bot), per
  Cloudflare's Verified Bots policy.
- **Web Bot Auth** (`app/services/web_bot_auth.rb`): every outbound fetch is
  signed per hop with RFC 9421 HTTP Message Signatures (Ed25519, covered
  components `@authority` + `signature-agent`, tag `web-bot-auth`), so
  bot-managed CDNs can verify us instead of 403ing by TLS fingerprint. The
  public key is served as a signed JWKS from
  `/.well-known/http-message-signatures-directory` (`WellKnownController`, tag
  `http-message-signatures-directory`, draft content type). Signing is dormant
  until `WEB_BOT_AUTH_KEY` (Ed25519 PEM, k8s secret / local-only) is set —
  generate with `rake web_bot_auth:generate_key`; `WEB_BOT_AUTH_AGENT` overrides
  the default `https://api.inbox2.com` directory origin. Verified against
  Cloudflare's reference `web-bot-auth` JS library. Apply (post-launch) at the
  Verified Bots program — well-formed Message Signatures waive the
  1,000-req/day minimum.

The reader's IP is never exposed — the sender only ever sees the proxy's egress
IP and the documented proxy User-Agent.

### 3.5 Graceful degradation — hosts that refuse the proxy

Some image CDNs sit behind bot management (e.g. Cloudflare on
`images.vestiairecollective.com`) that 403s **any** server-side client by TLS
fingerprint — a browser User-Agent and full header set don't help, so the Rails
proxy can never fetch from them (the controller returns 502). Real devices pass
(CFNetwork/WebKit/Android stacks are indistinguishable from normal app traffic).

Each platform counts the proxy fetches the upstream refused and shows a second
banner — *"N images couldn't be loaded privately"* — whose explicit **Load
directly** action fetches **only those images** from the reader's device. This
is a consented, minimal IP exposure: only the hosts that blocked the proxy ever
see the reader, and never automatically.

- **Web/desktop** (`useRemoteImages` + `ProxyFailedBanner`): accepting rebuilds
  the iframe with `img-src` relaxed to `https:`/`http:`; the hook re-proxies and
  only still-failing images fall back to their original URLs.
- **iOS** (`MessageBodyWebView` + `ImageProxy.fetchDirectDataURI`) and
  **Android** (`MessageBodyWebView.kt` + `ImageProxy.fetchDirectDataURI`): the
  failed jobs are re-fetched natively and swapped in as `data:` URIs, so the
  WebView CSP stays strict (`data: blob:` — never relaxed).

---

## 4. Quote & signature collapsing

`lib/quoteDetector.js` (`detectQuotes`) and `lib/signatureDetector.js`
(`detectSignatures`) detect quoted history and signature blocks (HTML-structural
selectors + line-based fallback) and wrap them in `[data-quoted-block]` /
`[data-signature-block]`.

- **HTML path**: `collapseBlocks()` converts each wrapper into a native
  `<details><summary>…</summary>…</details>` — collapsing works without
  JavaScript (the iframe has none). The quote `<details>` is opened by default
  only when the message is a bare forward (no real body text remains).
- **Plain-text path**: `QuotedText` keeps its React toggle buttons.

---

## 5. Plain-text path — `components/MessageCard/QuotedText.jsx`

Plain-text emails have no images, so no iframe/proxy is needed and they render
inline so they match the app's (dark) theme:

1. `linkifyText` (in `ConversationDetail`) makes URLs clickable.
2. `sanitizeEmailHtml`: `DOMPurify` (FORBID the same dangerous/remote tags +
   `<style>`), then **dark-mode colour adaptation** — strips dark text colours /
   light backgrounds that would be unreadable on the dark surface, preserving
   intentional accent colours — then `blockRemoteContent` (a no-op for plain text).
3. Quote/signature split with collapse toggles.
4. Rendered via `dangerouslySetInnerHTML`; links intercepted by
   `handleBodyLinkClick` → `openLink`.

---

## 6. File map

| File | Role |
|------|------|
| `ui/web/src/components/ConversationDetail/ConversationDetail.jsx` | chooses HTML vs plain (`isHtml`), builds `body` |
| `ui/web/src/components/MessageCard/MessageCard.jsx` | branches to `EmailFrame` or inline `QuotedText` |
| `ui/web/src/components/MessageCard/EmailFrame.jsx` | HTML render: srcdoc build, CSP, iframe wiring |
| `ui/web/src/components/MessageCard/QuotedText.jsx` | plain-text render + dark-mode colours + quote toggles |
| `ui/web/src/lib/blockRemoteContent.js` | neutralize remote image/bg/SVG vectors |
| `ui/web/src/hooks/useRemoteImages.js` | proxy/direct load decision + banner state |
| `ui/web/src/components/RemoteContentBanner/` | split "Show images" button + dropdown |
| `ui/web/src/lib/safeSenders.js`, `alwaysShowImagesPref.js`, `imageProxyPref.js` | per-sender / global / proxy prefs |
| `ui/web/src/lib/linkifyText.js` | plain-text → HTML with clickable links |
| `ui/web/src/lib/quoteDetector.js`, `signatureDetector.js` | quote/signature detection markers |
| `ui/web/src/lib/openLink.js` | link routing (in-app vs system browser) |
| `api/app/controllers/api/v1/image_proxy_controller.rb` | server-side image proxy |
| `api/app/services/private_address_guard.rb` | SSRF guard |

---

## 7. Testing against emailprivacytester.com

Send the test email to a connected account and open it. How to read results:

- The only signal that matters is **whether the reader's real IP appears**, not
  red vs. green. A "red" test only means *something* loaded it.
- Expected IPs: `inbox2-image-proxy` (our proxy — IP hidden ✓). The reader's real
  IP should appear **only** if they clicked "Show images" with no key.
- A **Gmail** account will always show `…GoogleImageProxy` (`ggpht.com`) — Gmail
  pre-proxies images server-side the moment mail arrives. That's the provider, not
  our client, and it doesn't expose the reader's IP. To test our client in
  isolation use an IMAP/MX account that doesn't pre-proxy.
- Tags we strip entirely (video/audio/object/iframe/picture-source/input) loading
  in a test means an external scanner rendered the raw mail — not our client.

---

## 8. Automated test harness

Every rendering case has a real example email in [`fixtures/email/`](../fixtures/email/)
(one `.html` per case, declared in `manifest.json`) driven through five layers. All
platforms render through the same `@inbox2/email-body` engine, so the fixture suite is a
cross-platform guarantee; the native clients add a drift guard + host-page contract.

| Layer | File | Env |
|---|---|---|
| Engine — `processBody()` over every fixture | `packages/email-body/__tests__/fixtures.test.js` | jsdom |
| Web/desktop wrapper — `EmailFrame.buildSrcDoc` (CSP, FRAME_FIT_CSS, `<details>`, `<style>` sanitize) | `ui/web/src/components/MessageCard/__tests__/emailRendering.test.jsx` | jsdom |
| `QuotedText` dark/light luma colour rewrite (needs real `<canvas>`) | `ui/web/src/components/MessageCard/QuotedText.stories.jsx` | browser |
| Bundle drift guard — iOS/Android `email-body.js` byte-identical to a fresh build | `packages/email-body/__tests__/bundleSync.test.js` | node |
| Native host-page contract — Swift/Kotlin WebView wiring + iOS↔Android parity | `packages/email-body/__tests__/nativeHostPage.test.js` | node |
| iOS WKWebView — every fixture through the shipped bundle | `ui/ios/Tests/EmailBodyRenderingTests.swift` | simulator |
| iOS layout — fixed/min-width emails reflow to a phone viewport (no overflow) | `ui/ios/Tests/EmailBodyLayoutTests.swift` | simulator |
| Android WebView — render + layout (counterparts of the iOS pair) | `ui/android/app/src/androidTest/.../EmailBody{Rendering,Layout}Test.kt` | emulator |

Run: `cd ui/web && yarn test:email`.

### Mobile rendering: reflow, and scale only what refuses to reflow

Gmail's mobile behaviour, and the rule both native readers follow: **text wraps into the
phone column at full size; the elements whose width *is* their design get scaled.** A
desktop/MJML email is one such element — Temu's 600px table has its fonts, buttons and
spacing sized for that column (body text 22.4px), so squeezing it into 390px wrecks the
design; scaling it to 0.65 keeps everything in proportion and lands the text at ~14.5px.
An ordinary business thread is the opposite: prose that already wraps, plus one 1600px
data table buried in a quote chain — there only the table may shrink.

The logic lives in the per-platform reader constant
(`ui/ios/Sources/Views/EmailReaderCSS.swift`, `ui/android/.../EmailReaderCss.kt` — a
constant so the layout harness renders through the exact shipped assets; **keep the two
identical**):

- **CSS** (`css`/`CSS`) — base styling only. No blanket `max-width:100%`: that would
  squeeze the MJML case. `#body{overflow-x:hidden}` clips the leftover layout box of
  anything the fit pass scaled (a transform shrinks paint, not layout width).
- **`fitJS`/`FIT_JS`** defines `window.__fitEmail()`. It walks down from `#body` into
  whatever overflows the column and takes the first option that works:
  1. **already fits** → leave it (this is why prose is never touched);
  2. **a descendant is the wide one** → recurse, so it reaches the wide table itself and
     not the wrapper holding it plus pages of prose;
  3. **its own box is too wide** → reflow it with `max-width:100%`;
  4. **can't reflow** (`table,img,pre,svg,video,canvas,iframe,object,figure` — width is
     the design) **or still doesn't fit** → `transform: scale()` that element alone, with
     a negative `margin-bottom` pulling back the layout height the transform didn't
     shrink, so `documentElement.scrollHeight` (what `postHeight` reports) stays true.

  Overflow is measured at the real column width, never `max-content` — max-content lays
  every block on one non-wrapping line and reports thousands of px for ordinary prose.
  The host runs it after insert and again as images settle / on collapse; each run undoes
  the previous one first (`[data-fit]`), so it's idempotent.

**Why not scale the whole `#body`?** That was the strategy until 2026-08-06 and it failed
on exactly the second case above: one 1600px quoted table dragged the entire email to ~0.2
and made all of it an unreadable thumbnail. An intermediate patch floored the scale at 0.5
and panned the remainder horizontally, which instead rendered ordinary mail wider than the
phone and cut off on the right. Both are gone; per-element is the fix for both symptoms.

Fixture flags asserted by the layout tests: `noOverflow` (nothing spills past the
viewport — `temu-fixed-width-overflow`, `wide-table-beside-prose`), `noShrink` (a prose
email is left at scale 1), `proseFullSize` (prose next to an ultra-wide element is still
painted at 1× — the thumbnail regression guard). Add a case: drop an `.html` in
`fixtures/email/cases` and a `manifest.json` entry — no code change. See
[`fixtures/email/README.md`](../fixtures/email/README.md).

After editing `packages/email-body/src`, run **`bin/sync-email-body`** to rebuild and copy
the bundle into the native clients (the drift guard fails otherwise). A stale embedded
bundle is how Android shipped without the `<pre>`-unwrap fix; the guard now prevents it.
