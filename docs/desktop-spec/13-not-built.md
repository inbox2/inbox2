---
part: "A"
title: Not built
subtitle: The known holes on the desktop.
eyebrow: Appendix
lede: The known holes, each with the doc that owns it. Each one is a choice to build later.
appendix: true
---

## Sync and data

- MX sync has had no long soak on a second person's device. The header/body AAD wire fix for sealed mail is still open (`docs/MX-Sync.md`, `docs/E2EE.md`).
- SQLCipher for the local database is not built; OS disk encryption is the protection (`docs/MX-Sync.md`).
- Sending while offline is out of scope (`docs/MX-Sync.md`).
- The `desktop-rust` CI job, where it runs at all, tests the shell and not the core (chapter 11).

## Calendar and invites

- Reminders: nothing is sent server-side, there is no UI to create one, `method: email` is ignored.
- No ICS export, no CalDAV.
- Google and Microsoft events cannot be opened in the web editor.
- Drag "All events" to another day and "this and following" on a drag are not handled.
- Sealed domains skip invite parsing.
- Out of office: one period, plain-text reply, no auto-reply for local channels.
- No room booking, no federated free/busy; counter-proposals have no expiry (`docs/Calendar.md`).
- Invites: target calendar not selectable; `DURATION` not parsed; no all-day detected meetings; the MX banner has no "Around this time" (`docs/Meeting-Invites.md`).

## Tray and notifications

- Tray: calendar data is local-channel only. There are no compose or new-event buttons. The title format is fixed, and the menu-bar text has no colour (`docs/Tauri-Desktop.md`).
- Sites that only declare `<link rel=icon>` show no icon in notifications (`docs/Notifications.md`).

## AI and agents

- Agentic filters: `auto_reply` sending deferred; no concurrency pool; no OS sandbox for `full_auto` (`docs/Agentic-Filters.md`).
- MCP server: sqlite-vec ANN, attachment ingestion, an approval-workflow UI, event notifications, scheduled workflows (`docs/Vector-MCP.md`).
- MCP client: the external reference (`TUL-412`) is not stored; no model-filled arguments; no 2024-11-05 SSE or 2026-07-28 client transport (`docs/MCP-Client.md`).
- Lore: per-member "done" on shared MX inboxes, hand-editing of entities and facts, and signature-block mining are missing. MX outbound is mined only by backfill (`docs/plans/lore.md`, `docs/Ontology.md`).
- WhatsApp in Lore: no person page for WhatsApp contacts; Send to… and auto mode untested on WhatsApp items (`docs/plans/lore.md`).
- Semantic search exists in the MCP server (`search_similar`) and the CLI (`~` prefix) but not in the desktop search screen.

## Around the inbox

- Touch Strip: market-cap sizing, week colouring and drag from the palette are missing. Location is IP-based. Working hours are fixed at 09 to 17 (`docs/Touch-Strip.md`).
- Mail import: no client screen to rename, delete or share labels (`docs/plans/mail-import.md`).
- Tracking: endpoint auth and opens scoping deferred (`docs/TODO.md`).
- Search results view: status, triage and delete keys are out of scope (`docs/Keyboard-Shortcuts.md`).
- No conversation snooze; the only snooze is for meeting reminders.

## Disk

- The "desktop app has the engine built in" checkbox is unchecked. Real Tauri-webview checks for gates G3 and G4 are pending. There is no sync client, no offline mode and no backup (`docs/plans/disk-spec.md`, `docs/plans/disk-build.md`).

## Release

- No Intel Mac build; no Windows Authenticode signature; no AppImage (`bin/release-desktop`).
- Windows was tested once (2026-11-07) on a Windows 11 26H2 ARM64 virtual machine running the x64 build under emulation. Not judged there: Acrylic (the VM has no GPU composition), HiDPI scaling on a real mixed-scale setup, system toasts (the custom card is used on Windows, so the toast path never ran), and the x64 build on real x64 hardware.
- Linux under XWayland at scale 2: the new-mail card window is created and shown but lands mid-screen (x computed from a logical work area with a physical offset). Tested 2026-11-07 in a Kubuntu 26.04 container; a scale-1 display is untested.
- The `imap` crate (2.4.1) panics on a tag mismatch after `ENABLE CONDSTORE QRESYNC` against Dovecot 2.4 (found 2026-11-07 in the Linux test, on every platform). The sync task fails and the poll retries; a server that advertises ENABLE with those extensions cannot sync until this is fixed. Linux: no tray popover and no tray title, no taskbar badge on GNOME or KDE, no custom new-mail card under Wayland, no WhatsApp, no native alert sounds, free AI lane only.
- `FoundationModelsBridge`: how it is built and bundled into the app is not documented in the code read for this book.
