---
part: "04"
title: Data
subtitle: The layout and upgrades of the SQLite file.
eyebrow: Data
lede: One file, inbox2.db, holds everything, in WAL mode. Channel mail and MX mail live in separate tables on purpose, and everything an AI agent may see is a view.
---

## The file

`<data dir>/inbox2.db`, opened by `core/sync/store/mod.rs` with WAL, foreign keys on and `busy_timeout` 5000. The data dir is `~/Library/Application Support/com.inbox2.desktop` on macOS (`.dev` for the dev identity), `$XDG_DATA_HOME/com.inbox2.desktop` on Linux, and `default_data_dir()` on Windows.

The same directory holds `engine.sock` (the bus), `.credential_key` (debug builds only; a release build keeps the key in the OS keychain), `mcp-token` (mode 0600) and `prompts.toml` overrides. It also holds the model bundles, the attachment cache and the log files.

The UI reads the same file through `tauri-plugin-sql` (`sqlite:inbox2.db`); the CLI reads it directly with WAL and `busy_timeout` 4000 and watches `PRAGMA data_version` for changes.

## Tables

The schema is one idempotent file, `core/migrations/001_create_schema.sql`: 53 tables, 3 FTS5 virtual tables, 2 views, 6 triggers, 51 indexes.

| Area | Tables | Purpose |
|---|---|---|
| Channel mail | `conversations`, `messages`, `tags`, `conversation_tags`, `memberships`, `notes`, `sync_state` | the offline mirror of a mailbox, shaped like the Rails model |
| Channel accounts | `external_accounts`, `external_account_credentials` (encrypted, with cloud-backup columns), `external_folders`, `message_provider_state` (provider ids, UIDs and flags per folder) | one row per connected mailbox |
| Write path | `writeback_actions` (the provider write-back queue), `outbox_messages` (durable sends and drafts, JSON `OutgoingMessage`), `draft_refs` | a queued action or send survives an app quit; a compose draft that was never saved or sent does not (`DraftProvider` keeps it in memory only) |
| Secrets and push | `app_secrets` (secrets kept out of webview localStorage), `vault_state`, `push_subscription_state` (Gmail watch and Graph renewal timing), `meta_subscription_state` (30-day relay lease) | |
| Open tracking | `tracked_tokens` (pixel token ↔ message), `message_opens` | |
| Calendar | `calendars`, `calendar_events`, `calendar_attendees` | provider calendars |
| Search and vectors | `messages_fts` (FTS5, triggers `messages_ai/ad/au`), `messages_vocab`, `message_embeddings` (f32 blobs), `embedding_queue`, `attachment_text` (opt-in), `vector_settings` (also holds `mcp_server_enabled`) | |
| AI | `ai_triage_queue`, `engine_settings` (key-value: processing window, `mx_schema_version`, `mx_busy_pushed:*`, lane choices, …), `bridge_announce` | |
| Agents and MCP | `agents`, `agent_audit_log`, `agent_approvals`, `agent_workflows`, `agent_templates`, `local_agents` (detected CLIs), `local_rules`, `agent_runs` | the MCP server's clients and the rule runner |
| Lore | `lore_todos`, `lore_entities`, `lore_facts`, `lore_mentions` | |
| Local WhatsApp | `wa_lore`, `wa_groups`, `wa_group_todos`, `wa_group_summaries` | |
| MX mirror | `mx_conversations`, `mx_messages` (verbatim JSON `payload`, `sealed`, `plain` for the opened sealed message, `search_text`), `mx_messages_fts` (3 triggers), `mx_notes`, `mx_directory`, `mx_sync_state` (cursor, backfill token, `reconciled_at`, `directory_at`), `mx_writeback_actions`, `mx_outbox` | inbox2-hosted mail |
| Agent views | `agent_conversations`, `agent_messages` | `UNION ALL` of channel and MX mail, minus every sealed message and every thread that contains one; dropped and recreated at every boot |

> **Decision** MX mail has its own `mx_*` tables (2026-09-20). A reader audit found about 400 SQL statements in 39 files that assumed every row is channel mail. Sharing tables would have meant double triage, rules firing twice and unread badges counted twice. Separate tables invert the default: a consumer that should see MX mail opts in on purpose. Source: `docs/MX-Sync.md`.

> **Decision** The `agent_*` views enforce the sealed rule for every agent read that goes through them. An MCP client may be a cloud model, so a sealed message, and any thread containing one, is never in them. Source: `docs/MX-Sync.md`.

> **Watch out** Not every agent read goes through the views. The MCP attachment tools (`shell/mcp/tools/attachments.rs`, `locate()`) query `mx_messages` directly for the attachment list and apply the same thread-wide check themselves. A new agent tool that reads `mx_*` directly must do the same; the views protect only the reads that use them.

## Schema upgrades

There is no incremental migration system on the client. On open the store runs, in order:

1. the PRAGMAs;
2. `mx::reset_if_outdated()`: if `engine_settings.mx_schema_version` is not `"2"`, drop the whole `mx_*` mirror (queued actions in `mx_outbox` and `mx_writeback_actions` are kept);
3. `execute_batch(SCHEMA_SQL)`, every statement `IF NOT EXISTS`;
4. `stamp_schema_version`;
5. a list of `ALTER TABLE … ADD COLUMN` statements whose errors are ignored;
6. `DROP TABLE IF EXISTS pending_changes`.

`AgentRunStore::ensure_schema()` (`shell/local_agents/store.rs`) drops and recreates `agent_runs`, `local_rules` or `local_agents` when a sentinel column is missing. On the JS side `tauri-plugin-sql` registers the same schema as migration 1.

> **Decision** The mirror is a cache. `mx_*` tables are never ALTERed; bumping `MX_SCHEMA_VERSION` drops and re-syncs them. Queued actions are user intent and are never dropped. Source: `docs/MX-Sync.md`.

> **Note** The server side is the opposite: prod PostgreSQL is never rebuilt, so every schema change there needs a real migration file. `CLAUDE.md`, Database / migrations.

## Secrets at rest

`external_account_credentials` and `app_secrets` are encrypted with a device-bound key (`core/sync/crypto.rs`). A release desktop build keeps that key in the OS keychain (the `os-keychain` feature, release profile only). A debug build, `tauri dev` and the mobile apps keep it in `.credential_key` beside the database, readable by the owner only. A Linux release build without a usable keyring (no daemon, no default collection) falls back to the same file on a fresh store and keeps using it from then on. A fresh store has neither the marker `.credential_keyring` nor an `inbox2.db`; any existing store never switches, so a passing keyring outage cannot leave the stored credentials undecryptable. The rows hold the OAuth tokens, the IMAP passwords, the `cloud_auth_token` (the inbox2 `ink_` key), `openai_api_key`, `typesafe_api_key` and `apollo_api_key`. The UI reaches them only through `get_secret`, `set_secret` and `clear_secret`. The credential vault (`vault_state`, `core/sync/vault.rs`) backs those credentials up to the cloud zero-knowledge, opened with the account password.

The database itself is plain SQLite. Protection at rest is the OS full-disk encryption; SQLCipher is the upgrade path and is not built.

## The tables the CLI uses

The CLI queries the channel tables: `external_accounts`, `conversations`, `messages`, `message_provider_state`, `external_folders`, `messages_fts`, `outbox_messages`. It queries the `mx_*` mirror with `mx_directory`. It reads three `engine_settings` keys (`space_taxonomy`, `personal_spaces`, `triage_labels`), the calendar tables and the `wa_*` tables. It reads `agent_*` and `local_rules` over RPC only. Its only direct writes are the optimistic status and read updates the desktop also makes before queuing a write-back.
