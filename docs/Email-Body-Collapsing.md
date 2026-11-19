# Email Body Collapsing

Quoted replies and signatures are collapsed behind `···` toggles in the message view, Gmail-style. Each section toggles independently — a message can have both a signature toggle and a quote toggle.

## Architecture overview

```
              raw HTML body (from API)
                      │
              ┌───────▼────────┐
              │ detectQuotes() │   Strategy 1: HTML-structural selectors
              │ quoteDetector  │   Strategy 2: Line-based quote patterns
              └───────┬────────┘
                      │  wraps matches in <div data-quoted-block>
              ┌───────▼──────────────┐
              │ detectSignatures()   │   Strategy 1: HTML-structural selectors
              │ signatureDetector    │   Strategy 2: "-- " delimiter (RFC 3676)
              └───────┬──────────────┘   Strategy 3: Contact-block heuristic
                      │  wraps matches in <div data-signature-block>
              ┌───────▼────────┐
              │  QuotedText    │   Splits HTML into body / signature / quoted
              │  (React)       │   Renders each with independent ··· toggle
              └────────────────┘
```

**Ordering matters.** Quotes are detected first because the signature detector skips anything inside `[data-quoted-block]` — it only collapses the current message's signature, not signatures buried inside quoted replies.

## Key files

| File | Purpose |
|---|---|
| `ui/web/src/lib/quoteDetector.js` | Detects quoted replies, wraps in `data-quoted-block` |
| `ui/web/src/lib/signatureDetector.js` | Detects signatures, wraps in `data-signature-block` |
| `ui/web/src/components/MessageCard/QuotedText.jsx` | React component: chains both detectors, renders toggles |
| `ui/web/src/components/MessageCard/QuotedText.module.css` | Toggle button + expanded signature styles |

## Quote detection

`detectQuotes(html)` returns `{ content: string, hasQuote: boolean }`.

### Strategy 1 — HTML-structural selectors

Parses the HTML with `DOMParser` and looks for known quote containers. If found, wraps each in `<div data-quoted-block>`.

| Selector | Client |
|---|---|
| `div.gmail_quote` | Gmail |
| `div.gmail_extra` | Gmail (older) |
| `blockquote[type="cite"]` | Apple Mail, Thunderbird |
| `div#divRplyFwdMsg` | Outlook |
| `div#appendonsend` | Outlook |
| `div#isForwardContent` | Outlook |
| `span.moz-cite-prefix` | Thunderbird |
| `blockquote` (generic) | Fallback — only if no named selectors matched |

### Strategy 1b — Unmarked header block

Outlook/Exchange often emits the quoted original with no marker class and no `-----Original Message-----` divider — just a header block:

```
From: Waseem Sadiq [mailto:waseem@tuli.com]
Sent: Monday, 29 September 2025 4:32 PM
To: …
Subject: …
```

Finds the first block element (`p/div/td/blockquote/table`) whose text **starts with** `From:` (multilingual: `Van`/`De`/`Von`/`Da`/`Fra`/`Från`) and contains ≥ 2 further header fields (`Sent`/`To`/`Cc`/`Subject`/`Date` + localized) in its first 400 chars. That element — plus a preceding `<hr>`, plus all its following siblings — is wrapped. It wins when it comes before every Strategy 1 match in document order — an Outlook reply quoting a Gmail/Apple thread carries a nested `blockquote` deep inside the quote, and that used to win and leave the whole quoted chain visible (2026-10-30).

Text is read via `blockText()` (turns `<br>` and block-element ends into newlines), not `textContent`, so `…@tuli.com]Sent:` doesn't glue two fields into one word and break the `\b` match.

### Strategy 2 — Line-based patterns

For plain-text emails converted to HTML (bodies with `<br>` tags instead of structured elements). Splits the HTML on `<br>` tags, strips tags from each line for text matching, and scans for the first line that matches a quote-start pattern. Everything from that line to the end is wrapped.

Patterns detected (with multilingual variants):

| Pattern | Example |
|---|---|
| `-----Original Message-----` | Outlook, Exchange |
| `-----Forwarded message-----` | Gmail forwarded |
| `On <date> <name> wrote:` | Gmail, Apple Mail reply |

Also matches a `From:` header block spread over consecutive `<br>` lines (same rule as Strategy 1b, looking 5 lines ahead).

Localized variants: French (`Le ... a écrit`), German (`Am ... schrieb`), Dutch (`Op ... schreef`), Spanish (`El ... escribió`), Portuguese (`Em ... escreveu`), Italian (`Il ... ha scritto`).

## Signature detection

`detectSignatures(html)` returns `{ content: string, hasSignature: boolean }`.

Run **after** `detectQuotes()` — skips anything inside `[data-quoted-block]` so only the current message's signature is detected.

### Strategy 1 — HTML-structural selectors

Same approach as quote detection. Looks for known signature containers and wraps them in `<div data-signature-block>`.

| Selector | Client |
|---|---|
| `div.gmail_signature` | Gmail |
| `div[data-smartmail="gmail_signature"]` | Gmail (newer) |
| `div#Signature` | Outlook |
| `div.moz-signature` | Thunderbird |
| `div.signature` | Generic |
| `div.email-signature` | Generic |

**Gmail prefix handling.** Gmail sometimes emits a separate `<div class="gmail_signature_prefix">-- </div>` before the signature div. When detected, both elements are wrapped together in a single `data-signature-block` so the entire block collapses as one unit.

### Strategy 2 — `-- ` delimiter (RFC 3676)

The standard email signature delimiter: a line containing exactly `--` followed by optional whitespace (`/^--\s?$/`). Everything from this line to the end of the body (or to the next `data-quoted-block`) is wrapped as the signature.

**False-positive guard:** the content after the delimiter must be ≤ 12 non-empty lines, and the delimiter must not be on the first line of the email.

### Strategy 3 — Contact-block heuristic

Catches signatures that omit the `-- ` delimiter entirely — just a name, optional company/title, and phone numbers appended at the end. Common in corporate email (e.g. Enron dataset).

```
Thank you,

Stephanie Sever          Justin Rostant
EnronOnline              Phone: 713-853-6460
713-853-3465             Mobile: 832-264-6333
```

**How it works:**

1. **Find contact lines.** Scan backwards from the last non-empty line. A contact line matches either:
   - Labeled: `/^(Phone|Mobile|Cell|Fax|Tel|Telephone|Office|Direct|Work|Home)\s*[:.]?\s*[\d(+]/i`
   - Bare phone: `/^\+?[(]?[\d][\d\s()._-]{6,}$/` (7+ digit string with separators)

2. **Walk upward for name/company.** From the first contact line, walk up absorbing short label lines (up to 3). A label line must be < 40 chars, ≤ 4 words, no digits — matches names (`Stephanie Sever`), companies (`EnronOnline`), and sign-offs (`Thank you,`) but rejects body prose (`Please let me know if you have any questions.`).

3. **Validate.** The topmost line of the block must pass the label check, and the block must not start at line 0 (which would wrap the entire message).

4. **Wrap surgically.** Only the detected block is wrapped — content after the signature (e.g. a shared URL below the contact info) is preserved outside the wrapper.

## UI component — QuotedText

`QuotedText` chains both detectors and renders the result:

1. Runs `detectQuotes(html)` → marks `data-quoted-block` sections.
2. Runs `detectSignatures(result)` → marks `data-signature-block` sections.
3. Parses the combined HTML, extracts each block type, and removes them from the body.
4. Renders: **body** → **signature toggle** (if detected) → **quote toggle** (if detected).

Each toggle is independent — expanding the signature doesn't expand the quotes, and vice versa. Expanded signatures render in `var(--text-tertiary)` to visually de-emphasize them.

## Adding new patterns

**New quote pattern:** Add a regex to `LINE_QUOTE_PATTERNS` in `quoteDetector.js`, or a CSS selector to `QUOTE_SELECTORS`.

**New signature container:** Add a CSS selector to `SIGNATURE_SELECTORS` in `signatureDetector.js`.

**New contact-info label:** Add the label keyword to `CONTACT_LINE_PATTERN` (e.g. `Extension`).
