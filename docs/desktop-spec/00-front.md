---
title: inbox2 Desktop
subtitle: The architecture of the desktop client.
eyebrow: Desktop client specification
edition: Edition 1 · November 2026 · built from main at the version printed in About
running: inbox2 Desktop specification
contact: inbox2.com · the source of this book is docs/desktop-spec in the inbox2 repository
---

## Scope and sources

This book describes the inbox2 desktop client as it is in the code on 2026-11-07. It covers the Tauri shell, the React UI, the shared Rust core and the SQLite file. It also covers the cloud and provider services they talk to. Every statement was checked against the repository. Where a check was not possible the text says "unverified".

It is written for the engineer who needs to know how the client is built before changing it. Chapters 1 to 5 are the architecture. Chapters 6 to 9 are the features and the rules they obey. Chapters 10 and 11 are release and tests. Chapter 12 lists the settled decisions. Appendix A lists what is not built.

### Scope marks and callouts

Paths are relative to the repository root. `ui/web/src` is shortened to `web/` and `ui/desktop/src-tauri/src` to `shell/`, `ui/desktop/core/src` to `core/`.

Scope marks say which mail a feature applies to:

| Mark | Meaning |
|---|---|
| **MX** | inbox2-hosted mail: a domain whose MX points at inbox2. Synced from the Rails API and mirrored locally in the `mx_*` tables. |
| **Local** | a connected mailbox (Gmail, Microsoft 365, IMAP) or a Meta channel. Synced by the Rust core straight from the provider, never through the API. |
| **Both** | works for both kinds of mail, usually through two code paths. |
| **Desktop** | only in the Tauri app. The browser build of the same UI leaves it out. |

Callouts:

> **Decision** A settled choice, with its date and reason. Chapter 12 lists them all.

> **Watch out** A trap that has cost time before.

> **Note** Background that helps but is not binding.

### Updating the specification

The chapters are Markdown in `docs/desktop-spec/`, the diagrams are Archify candidates in `docs/diagrams/`, and `docs/manual/build.py` prints the PDF. `docs/manual/README.md` says how to rebuild all three. Change the chapter, rebuild, commit the PDF with it.

### Screenshot sources

The screenshots are the product captures from the website (`website/public/assets/shots`), taken in demo mode with the Brightfold demo data, so no real mail appears. Cut-outs are crops of the same captures.
