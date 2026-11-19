# Explorer — Command Center Network Graph

The Explorer is the default landing view (`/:orgSlug`). It renders a force-directed network graph showing all mailboxes in the domain, the people who email them, and the relationships between them.

**Two graphs, one renderer (2026-10-20).** The default view is now the **entity graph**: the organizations, people, products and projects Lore mines from mail ([Ontology.md](Ontology.md)). The original **mailbox graph** described in the rest of this file is one toggle away (sidebar: *Entities* / *Mailboxes*, kept in `explorerStore.graphMode`).

### Entity graph

- **Data**: MX — `GET /api/v1/orgs/:id/lore/graph` once per org (by slug, like the mailbox graph); desktop — the local-channel `lore_graph` Tauri command. `useEntityGraph` (in `hooks/useExplorerGraph.js`) fetches both and `lib/entityGraph.js` `mergeEntityGraphs` folds them: one node per person (address), organization/product (domain), else kind + name; links remapped and summed per (source, target, label). Node `weight` = mention count (threads), which also drives the radial force.
- **Shape** (both sources): `{ nodes: [{ id, kind, name, email_domain, address, weight }], links: [{ source, target, label, weight }] }`, top 300 entities by mentions; links are `works_at` / `client_of` / `uses` / `about` facts between two listed nodes.
- **Rendering**: `paintEntityNode` in `lib/explorerPaint.js` — a contact-size card with an avatar ring in the kind's hue (`--accent-info` organization, `--accent-teal` person, `--accent-purple` product, `--accent-warning` project). Organization and product nodes draw their domain logo from `loadBrand(domain)` (`hooks/useBrand.js`, the brand endpoint), top 80 by weight; each loaded image triggers one coalesced repaint. `works_at` links use the internal-link style, the rest the shared-tag style.
- **Navigation**: click an organization → `/lore/org/<domain>`, a person → `/lore/person/<address>`; products and projects centre the camera (no page yet). The sidebar lists each kind (top 25, filtered by the search box) as keyboard-reachable `NavItem`s doing the same. The link pair panel and the KPI strip are mailbox-graph only.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Frontend (react-force-graph-2d)                            │
│  Canvas-based, zoom/pan/drag, debounced search filter       │
│                                                             │
│  GET /api/v1/orgs/:id/mailboxes/stats   ← real-time        │
│  GET /api/v1/orgs/:id/mailboxes/graph   ← precomputed      │
├─────────────────────────────────────────────────────────────┤
│  MailboxGraphAggregator (service object)                    │
│  3 SQL aggregations → { nodes, links }                      │
├─────────────────────────────────────────────────────────────┤
│  RefreshMailboxGraphJob (Solid Queue, every 2 min)          │
│  Upserts mailbox_graph_snapshots row per org                │
│  Skips if source_version unchanged                          │
├─────────────────────────────────────────────────────────────┤
│  PostgreSQL                                                 │
│  conversations table: to_address, from_address, read, tags  │
│  mailbox_graph_snapshots table: payload JSONB               │
└─────────────────────────────────────────────────────────────┘
```

## Graph data model

### Node types

| Type | Description | Source | Visual |
|------|-------------|--------|--------|
| `mailbox` | A `to_address` in the org's conversations | `GROUP BY to_address` | Large card with urgency ring, unread/total badges |
| `member` | An internal sender (`@{org.domain}`) | `GROUP BY from_address` where `>= 2` conversations | Small card, steel accent |
| `external` | An external sender | Same, but domain != org domain | Small card, teal accent |

### Link types

| Kind | Meaning | Source |
|------|---------|--------|
| `inbound` | External sender → mailbox | `from_address` → `to_address` pairs |
| `internal` | Internal sender → another mailbox | Same, but sender is also a known mailbox |
| `shared_tag` | Two mailboxes share a tag | Tag co-occurrence across mailboxes |

Links carry a `weight` (number of conversations or tag co-occurrences).

### Analytics (in the same snapshot)

Mailbox nodes additionally carry:

- `waiting` / `waiting_over_24h` / `oldest_waiting_at` — open conversations whose latest non-draft message is inbound (someone is waiting on a reply), computed with a LATERAL last-message lookup per open conversation.
- `recent` / `prior` — conversation volume this 7 days vs the prior 7 (week-over-week trend).
- `urgency` — now weighted `0.3·unread_ratio + 0.2·open_pressure + 0.5·waiting_age` (age saturates at 72h), so red rings mean "people have been waiting", not just "unclicked mail".

The payload also has a `stats` block (org-level KPIs): `inbound_today`, `recent7`/`prior7`, `waiting`, `waiting_over_24h`, `oldest_waiting_at`, `busiest` (mailbox), `top_external_domain` (top sender domain this week + prior-week count). Served by both `stats` and `graph` endpoints.

`GET /mailboxes/pair?source=&target=` is the link drill-down: live counts, unread, last activity, and the 5 most recent conversations between two addresses (direction-agnostic).

### Thresholds

The aggregator caps output to keep the graph interactive:
- **100 mailboxes** (top by unread, then total) — `DEFAULT_MAX_MAILBOXES`
- **150 contacts** (top by conversation volume, minimum 2 conversations) — `DEFAULT_MAX_CONTACTS`
- Shared-tag links skipped when mailbox count > 200 (O(n²) pairs)

## Frontend

### Tech

- **`react-force-graph-2d`** — d3-force physics + Canvas rendering. Handles 5K+ nodes.
- **`warmupTicks={60}`** — runs 60 simulation ticks synchronously before first paint, so the graph appears pre-positioned with no animation delay.
- **`cooldownTicks={30}`** — runs 30 more ticks for fine adjustment, then freezes. No ongoing physics cost.

### Search / filter

- Text input overlaid on the graph canvas, focused with `/` key, cleared with `Esc`.
- 200ms debounce via `useDebounce` hook.
- Filters client-side: matching nodes (by name or address) + their direct neighbors stay visible. Non-matching nodes render as dimmed outlines. Non-matching links are hidden entirely.
- Match count badge shows `N nodes` next to the input.

### Custom Canvas rendering

Nodes are painted as glass-morphism cards on Canvas (not DOM):
- Rounded rectangle with semi-transparent fill
- Avatar circle with initial letter
- Name + monospace email address
- Unread badge (red) top-right, total badge (grey) bottom-right
- Urgency ring: green (< 0.3), amber (0.3–0.6), red (> 0.6)

Links are dashed quadratic curves with warm gold highlighting on hover.

### Analytics UI

- **KPI strip** across the top of the graph (all modes — MX, local, unified): inbound today, waiting >24h (red when non-zero), this-week volume with ▲/▼ week-over-week, busiest mailbox, top external sender domain (MX-sourced only). Local channels compute the same analytics client-side (`buildLocalGraph` + two correlated last-message subselects in `fetchLocalRows`); unified mode sums MX + local per node and org-wide. Each KPI is a **toggle-pill filter**: clicking it dims the graph to matching nodes + their neighbors through the same match/visible sets the search uses (today / waiting>24h / active-this-week mailboxes, the busiest mailbox, or every node on the top sender domain). Pills with a zero count are disabled; a pill filter and text search are mutually exclusive; `Esc` clears (pair panel → pill → search).
- **Needs attention** sidebar group: top 10 mailboxes by oldest unanswered inbound conversation, badge = count waiting >24h.
- **Trend badge** on mailbox cards (top-left): ▲/▼ week-over-week percentage, drawn only when volume ≥ 5 and change ≥ 10%.
- **Link click → pair panel**: overlay card with live conversation count, unread, last activity, 5 recent subjects (from the pair endpoint in single-MX mode; local/unified modes show link weight only), and an "Open in Mail" button filtered to the sender side. `Esc` closes.

### Navigation

- Clicking a mailbox node → `/:orgSlug/mail?to={address}`
- Clicking a contact node → `/:orgSlug/mail?from={address}`
- Chrome tabs: Explorer (active) ↔ Mail

## Precomputed snapshot

### Why

On the Enron dataset (118K conversations, 13.5K mailboxes):

| | p50 | p95 |
|---|---|---|
| Naive aggregation | 221ms | 288ms |
| Snapshot read | 4.2ms | 6.3ms |

**52x speedup.** The naive path runs 3 GROUP BY queries with FILTER expressions across the full conversations table. The snapshot path reads one JSONB row.

### How

1. `MailboxGraphAggregator#source_version` — SHA256 of `(org_id, conversation_count, max_updated_at)`, truncated to 16 hex chars.
2. `RefreshMailboxGraphJob` — runs every 2 minutes via Solid Queue recurring schedule. Compares `source_version` against existing snapshot. Skips if unchanged. Otherwise runs the aggregator and upserts.
3. `GET /mailboxes/graph` — returns the snapshot via `MailboxGraphSnapshotSerializer`. Returns 202 if no snapshot exists yet (triggers first computation).
4. `GET /mailboxes/stats` — real-time fallback, used by the current frontend.

### Table

```
mailbox_graph_snapshots
├── organization_id  (unique FK)
├── payload          (JSONB: { nodes: [...], links: [...] })
├── computed_at      (when last refreshed)
├── source_version   (staleness fingerprint)
└── key              (public ID: mgs_...)
```

## Files

| File | Purpose |
|------|---------|
| `api/app/services/mailbox_graph_aggregator.rb` | 3-query aggregation → `{ nodes, links }` |
| `api/app/jobs/refresh_mailbox_graph_job.rb` | Solid Queue job, upserts snapshot |
| `api/app/controllers/api/v1/mailboxes_controller.rb` | `stats` (real-time) + `graph` (snapshot) endpoints |
| `api/app/serializers/mailbox_graph_snapshot_serializer.rb` | Alba serializer for snapshot |
| `api/app/models/mailbox_graph_snapshot.rb` | Model with `key_prefix "mgs"` |
| `ui/web/src/pages/command/CommandCenterPage.jsx` | Force graph + search + Canvas rendering |
| `ui/web/src/pages/command/CommandCenter.module.css` | Styles for canvas, search overlay, states |
| `api/lib/tasks/mailbox_graph_benchmark.rake` | `rake mailbox_graph:benchmark` |

## Benchmark

```sh
cd api
rake mailbox_graph:benchmark
```

For meaningful numbers, restore the Enron dump first:

```sh
bin/rails db:drop db:create
pg_restore --no-owner --dbname=api_development ../data/enron_db.dump
```
