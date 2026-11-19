---
part: "11"
title: Tests
subtitle: The four suites and the pre-push gate.
eyebrow: Tests
lede: Four suites cover the desktop. Rust covers the core and the shell, vitest and Storybook the UI, pytest the CLI. Only the UI suite runs before a push.
---

## Rust

| Location | Tests | Largest files |
|---|---|---|
| `core/` | 555 (`#[test]` and `#[tokio::test]`) | `store/mod.rs` 62, `interactive.rs` 34, `calendar.rs` 34, `engine/tests.rs` 32, `store/mx.rs` 29, `gmail_mail.rs` 28, `ai_triage.rs` 25, `mx_sync.rs` 25 |
| `shell/` | 118 | `local_agents/store.rs` 17, `whatsapp.rs` 12, `local_agents/adapters.rs` 9, `mcp/server.rs` 8, `harness.rs` 8, `ai/inference.rs` 8 |
| `ui/desktop/src-tauri/tests/` | 19 | `imap_integration.rs` 9 (GreenMail, `--ignored`), `sync_conformance.rs` 6 (the `ProviderAdapter` contract), `ai_inference.rs` 4 (`--ignored`, needs models) |

Fixtures: `fixtures/parity/fixtures.json` (the Ruby/Rust parity set, `jev_triage` included; `core/parity_tests.rs`), `core/fixtures/triage-eval.json`, `core/testdata/sealed_by_{go,js}.json` (seal interop). `core/src/sync/mx_sync.rs` tests mock every MX endpoint with wiremock.

```sh
cd ui/desktop && cargo test --workspace                 # core + shell
cd ui/desktop/src-tauri && cargo test --test imap_integration -- --ignored   # GreenMail via docker compose --profile test
cd ui/desktop/src-tauri && cargo test --test ai_inference -- --ignored --test-threads=1
cargo run --bin sync_check -- --account <key> [--json]   # live end-to-end sync into a temp DB
cargo run --bin triage-eval -- fixtures/triage-eval.json  # exits non-zero on a regression
```

> **Watch out** Never run `cargo test` against the desktop crates while `tauri dev` is running; it contends for the Cargo lock.

## UI

Vitest (`ui/web/vite.config.js`) has two projects. `unit` runs in node over `src/**/__tests__/**/*.test.{js,jsx}` plus `packages/email-body/__tests__`. `storybook` runs `@storybook/addon-vitest` in headless Chromium through Playwright. There are 98 unit test files: `lib/__tests__` 52, `lib/disk/__tests__` 13, `hooks/__tests__` 9, `lib/ai/__tests__` 6, `stores/__tests__` 5, `styles/__tests__` 2, and one or two in each component that has logic. There are 108 Storybook stories.

Playwright (`ui/web/e2e/`) has five specs: console, domain access, onboarding, routing and team. It also has 17 Disk specs with their own config on chromium, firefox and webkit. The Tauri app has no end-to-end test.

Guards that act as tests:

| Guard | Rule |
|---|---|
| ESLint `react/forbid-dom-props` | inline `style` is an error (spec F1.3); the build runs lint first |
| ESLint `no-restricted-imports` | mail pages must import `lib/localFirstApi`, never `lib/api`; `lib/providers` and the OAuth modules may not be imported statically |
| ESLint | `document.addEventListener('mousedown')` only in the popover primitives; raw checkboxes only in `Checkbox`, `Switch`, `management` |
| `styles/__tests__/colorLiterals.test.js` | colour literals per file may only go down (baseline file) |
| `styles/__tests__/tokens.test.js` | every token used in a CSS module exists |

```sh
cd ui/web && yarn lint && yarn test        # eslint + vitest
cd ui/web && yarn test:email               # the email-body package + MessageCard
cd ui/web && yarn e2e                      # Playwright (needs a seeded API: yarn e2e:seed)
cd ui/web && yarn storybook                # :6006
```

## CLI

There are 218 tests in `ui/cli/tests/`. The largest files: `test_app.py` 77, `test_lore.py` 13, `test_search.py` 12, `test_bodyrender.py` 11, `test_collapse.py` 11, `test_parity.py` 11, `test_whatsapp.py` 11, `test_db.py` 10, `test_rules.py` 9, `test_accounts.py` 8, `test_inbox_rule.py` 8. Smaller files cover drafts, intelligence, MX, the CLI commands, Send to, remote images, the bus and live refresh. The harness is Textual's `App.run_test()` with a `Pilot`, headless, over a seeded temporary database and a `FakeBus`. `test_bus.py` and `test_live_refresh.py` use a real Unix socket with a small in-process host.

```sh
cd ui/cli && uv run pytest -q
```

## Gates before main

| Gate | Runs |
|---|---|
| pre-push hook (`.git/hooks/pre-push`) | `yarn lint`, `vitest run` (UI); `rubocop`, `rspec` (API) |
| GitLab CI (`.gitlab-ci.yml`) | deploy stages only: `deploy_pushleft`, `deploy_pages`, `deploy_website` |
| `.github/workflows/ci.yml` | a `desktop-rust` job (`cargo test --all-targets` in `src-tauri`, plus the two ignored suites) and web and API jobs. The repository lives on GitLab, so this file runs only if a GitHub mirror exists (unverified). Even there it runs from `src-tauri` without `--workspace`, so it would test the shell and skip the core's 555 tests. |
| release | `bin/release-desktop` runs no tests |

> **Watch out** No automated gate runs the Rust suites, the CLI suite or the Playwright specs before code reaches main. The pre-push hook tests the working tree, so dirty UI files from another session can block an unrelated push.

