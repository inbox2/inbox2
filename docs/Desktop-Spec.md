# inbox2 Desktop specification

The architecture and implementation reference of the desktop client. The book is `docs/desktop-spec/inbox2-desktop-spec.pdf`; its chapters are the Markdown files beside it, printed by `docs/manual/build.py` with diagrams from `docs/diagrams/`.

```sh
docs/diagrams/build.sh system-map            # rebuild one diagram (repeat per diagram)
uv run docs/manual/build.py docs/desktop-spec docs/desktop-spec/inbox2-desktop-spec.pdf
```

| Chapter | File | Covers |
|---|---|---|
| Front | `00-front.md` | how to read, scope marks, conventions |
| 1 Overview | `01-overview.md` | the three layers, processes, dev/prod identities, where things are |
| 2 The Tauri shell | `02-shell.md` | windows, menu, plugins, capabilities, deep links, all 183 commands, events, macOS native pieces |
| 3 The Rust core | `03-core.md` | crates, module layers, the run loop, workers, events |
| 4 Data | `04-data.md` | the SQLite file, every table by area, the agent views, schema upgrades, secrets at rest |
| 5 Sync | `05-sync.md` | local channels, write-back and outbox, cloud push, the MX mirror pass, sealed mail |
| 6 Features | `06-features.md` | routes, setup, mail, calendar, Lore, WhatsApp, around the inbox, stores |
| 7 Settings | `07-settings.md` | every setting with its key and the feature it affects |
| 8 AI and agents | `08-ai.md` | lanes, prompts, triage, Lore, local rules and agents, MCP server and client |
| 9 Security and privacy | `09-security.md` | what leaves the machine, secrets, sealed mail, sign-in, rendering, updates |
| 10 Build and release | `10-release.md` | versioning, `bin/release-desktop`, manifest, publishing, in-app update |
| 11 Tests | `11-tests.md` | Rust, UI, CLI suites; guards; what runs when |
| 12 Decisions | `12-decisions.md` | the settled decisions with date, reason and source; where the docs disagree |
| A Not built | `13-not-built.md` | known holes by area |

Diagrams: `system-map`, `process-topology`, `core-layers` (architecture), `channel-sync` (sequence), `mx-sync`, `agentic-filter` (workflow).

Keep it current: change the chapter, rebuild the PDF, commit both. A decision that changes gets a new row in chapter 12 with its date; the old row stays with "superseded".

The CLI gap check is a separate working file, `docs/CLI-Gap.md`: it exists to bring `ui/cli` closer to the desktop and is deleted when the gaps are closed.
