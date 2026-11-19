# Cross-language parity (Ruby ↔ Rust)

Five pieces of mail-domain logic are implemented **twice** — once in the Rails
API (Ruby, server-side, for MX inbound mail) and once in the shared Rust core
(`ui/desktop/core/`, client-side, for offline Gmail/Office365 channels). The two
paths genuinely both need the logic (MX threads/snippets/classifies on the
server; local channels do the identical work offline on the client with no API
access), so the duplication is structural, not accidental.

Nothing previously tested that the two copies agree. This directory closes that
gap and pins the parts that have been reconciled.

## How it works

[`fixtures.json`](fixtures.json) is a single shared corpus consumed by **both**
test suites:

| Engine | Test | Run |
|--------|------|-----|
| Ruby | `api/spec/services/cross_language_parity_spec.rb` | `cd api && bundle exec rspec spec/services/cross_language_parity_spec.rb` |
| Rust | `ui/desktop/core/src/parity_tests.rs` | `cd ui/desktop/core && cargo test --lib parity_tests::` |

Each module has two case sets:

- **`agreed`** — one `expected` value asserted **identically on both engines**.
  This locks behaviour that matches so it can't silently drift.
- **`divergences`** — a per-engine `ruby` and `rust` value, each asserted against
  its own engine. This *pins* remaining drift: if either side changes, its test
  breaks and forces this file (and the table below) to be updated.

## Reconciled (2026-06-23)

Drift that was found and then **fixed**, so these cases are now in `agreed`:

| Module | What changed |
|--------|--------------|
| **SnippetBuilder** (Ruby → Rust) | Over-length snippets are now hard-cut to 200 chars with no `…` ellipsis (was ActiveSupport `truncate`). HTML source pasted into the `text/plain` part is now stripped, like the HTML-only path (was kept verbatim). |
| **SubjectNormalizer** (Rust ← more languages) | Rust's prefix tables were expanded to Ruby's coverage: extra Latin locales (`rif`, `ynt`, `atb`, `va`/`vá`, `res`, `fs`, `rép`/`rep`, `beantw`, `svar`) and a new **colon-required** non-Latin bucket (Korean, Japanese, Hebrew, Arabic incl. the multi-word `إعادة توجيه`, Hindi, Greek, Cyrillic). Colon-required avoids stripping common words like Bulgarian "На". |
| **RuleExecutor conditions** (Ruby → Rust) | Empty condition set now **never matches** (was matches-all). Field names are `from`/`to` on both engines — the Rails side's old `sender`/`recipient` names were dropped (no back-compat aliases; the rules UI and local matcher already use `from`/`to`). Note: `sender`/`recipient` still exist independently as **View** filter fields. `has_attachment` is a **real boolean** with `is_true`/`is_false` operators (was a `"false"` stub). |
| **SpaceClassifier prompt** (Ruby → Rust) | The "no space fits" instruction is now `reply with: triage` on both engines (was `none` on the Ruby side). |

## Remaining divergences

**Jev triage request** (`fixtures.json → jev_triage`, agreed): the built-in
labels, the priority levels and the question JSON Jev receives must be identical
on both engines (key order included). The old SpaceClassifier prompt section is
gone: both engines now classify with Jev (see [docs/Triage.md](../../docs/Triage.md)).

**SnippetBuilder** (pinned in `fixtures.json → snippet.divergences`): the Rust
core grew a residual-tag pass (`strip_known_tags`, for lone tracking-pixel
`<img>` tags in otherwise-plain `text/plain` parts) that Ruby doesn't have, so
a lone known-element tag like `<a>` is dropped by Rust and kept by Ruby.
Unknown `<name>` words and stray `<` stay prose on both.

The SubjectNormalizer *mechanics* (not language coverage) also still differ.
These were left alone deliberately — the request was to expand Rust's language
support, not to unify the parsing mechanics. Each is pinned in
`fixtures.json → subject.divergences`:

| Input | Ruby | Rust |
|-------|------|------|
| `RE : x` (space before colon) | not stripped | stripped |
| `回复：x` (full-width colon) | not stripped | stripped |
| `回复 x` (East-Asian prefix, no colon) | not stripped | stripped |
| `Re(2): x` (paren count) | not stripped | stripped |
| List tag > 40 chars | kept (40-char cap) | stripped (no cap) |
| `[list]` with nothing after | stripped → `""` | kept |

To reconcile one of these later: change the production code, flip the case from
`divergences` to `agreed` (single `expected`), and both suites enforce it.

**Sign-in code / link detection** (`fixtures.json → otp`, agreed, 2026-10-13):
`OtpDetector.detect` (Ruby, inbox2-hosted push) ↔ `otp::detect` (Rust, local
channels). Same regexes on both sides; Rust has no lookahead, so its
letters-plus-digits code rule is a post-check (`is_code`) rather than inside the
pattern. Contract: [docs/Notifications.md](../../docs/Notifications.md).

## Not covered here

`mail_header_encoding.rb` ↔ `sync::adapters::util::decode_rfc2047` are
complementary (Ruby **encodes** outbound headers, Rust **decodes** inbound), not
the same function, so there's no single input→output contract to pin. Threading
*assembly* (`inbound_mail_processor` ↔ `threading::find_or_create_conversation`)
shares the In-Reply-To/References/subject strategy but is tangled with each
side's storage layer; only its pure sub-parts (subject normalization above) are
fixture-tested.
