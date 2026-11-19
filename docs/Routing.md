# Web Routing — User → Org → Domain

How the web/desktop client maps URLs to the **user → organization → domain** hierarchy,
and the rules every navigation must follow. This is the single source of truth for the
mail-client URL scheme; keep it in sync with `ui/web/src/routes.jsx`,
`ui/web/src/stores/navigationStore.js`, and `ui/web/src/lib/workspace.js`.

## The model

- A **user** belongs to one or more **organizations** (`org_…`).
- An **org owns many first-class, equal domains** (`dom_…`) — there is no "primary" flag in
  the data. One domain is the **default** (the oldest, surfaced as `org.domain`); it stands
  in for the org where a single representative is needed.
- All mail for a connected domain lands in the org's unified MX pool; a **domain** is a slice
  of that pool (`?domain=dom_…` on the API). See the two-sync-modes note at the bottom — this
  doc is about **MX** (inbox2-hosted) domains; external Gmail/IMAP accounts are a separate axis.

## Slugs

Org slugs never take one of the app's top-level paths (`disk`, `console`, `mail`, `share` and the rest in `Organization::RESERVED_SLUGS`, added 2026-10-04): an org named "Disk" gets `disk-1`. Before that list there was no reserved-slug check at all. Domain slugs cannot collide, as a domain name has a dot.

Every URL that addresses a workspace uses a **slug**, never a raw public id:

| Slug | Where it comes from | Example |
|------|--------------------|---------|
| **Domain slug** | `DomainSerializer#slug` = `name.parameterize` | `ilabexperiment.xyz` → `ilabexperiment-xyz` |
| **Org slug** | `Organization#generate_slug` = `name.parameterize` (org name = default domain) | `inbox2.com` → `inbox2-com` |

Because domain names are globally unique, **domain slugs are globally unique** and each
addresses exactly one `(org, domain)` pair. The org slug is `org.name.parameterize`, which
equals the **default domain's** slug only when the org is named after that domain (the common
single-domain case, e.g. org "inbox2.com" → `inbox2-com` = the `inbox2.com` domain slug). When
the org has a distinct name (e.g. "Acme Corp" → `acme-corp`, default domain `acme.com` →
`acme-com`) the two differ — and that's fine, because the two slugs mean different things:

- a **domain slug** → that one domain's pool.
- the **org slug** → the whole org (all domains, member-scoped).

> The API sends `slug` on every domain inside `org.domains[]` (via `OrganizationSerializer` →
> `DomainSerializer`). The client never re-derives slugs — it reads them, so the two can't drift.

## URL scheme

The **domain occupies the path's first segment** (the "workspace slot"). The `?domain=` query
param that an earlier iteration used is **gone from the browser URL** — it now rides the path.

| URL | View | Domain filter |
|-----|------|---------------|
| `/:orgSlug/mail` | **Unified** inbox (cross-channel: all MX domains + external accounts) | none |
| `/:orgSlug/mail/inbox` | Whole **org** MX pool (member-scoped) | none |
| `/:domainSlug/mail/inbox` | That **domain's** MX pool | that domain |
| `/:slug/mail/inbox?space=spc_…` | Org-wide MX pool filtered by a **Space** | none (Space is org-wide) |
| `/:slug/mail/account/:accountKey` | An external (Gmail/IMAP) account's inbox | n/a |
| `/:slug` | Command Center (Explorer graph) | org-level |
| `/:slug/search`, `/calendar`, `/spaces`, `/settings` | Org-level surfaces | org-level |
| `/console`, `/console/domains/:slug`, `/console/api-keys` | Admin console (org-level). Since 2026-10-07 on its own host, `console.inbox2.com`, with the same paths at the root (`/`, `/domains/:slug`); `/console/...` there drops the prefix, and the mail and disk hosts send `/console/...` over (`VITE_CONSOLE_ORIGIN`). The console host also keeps sign-in and `/onboarding`; anything else goes to mail. On it `/disk` is the console's Disk admin page, and deeper `/disk/...` paths go to Disk. Desktop and dev keep `/console`. `lib/consoleHost.js` | org-level |
| `/disk/...` | Disk (files). No slug in the path since 2026-10-04: one org at a time, picked by `?org=`, the remembered choice or the current org. On `disk.inbox2.com` the same paths sit at the root (`/c`, `/d/...`) and `/disk/...` redirects there. See docs/plans/disk-build.md section 1 | org-level, not in the URL |

Org-less variants (`/mail`, `/mail/account/:key`, `/mail/search`, `/explorer`) exist for the
desktop standalone/local-channel mode where there is no org.

### Worked example — org `inbox2.com` with three domains

```
/inbox2-com/mail                    → unified (all domains + external)
/inbox2-com/mail/inbox              → inbox2.com pool
/ilabexperiment-xyz/mail/inbox      → ilabexperiment.xyz pool
/messy-sh/mail/inbox                → messy.sh pool
/inbox2-com/settings                → org settings (always the org's primary slug)
```

## Resolution

### Frontend — `lib/workspace.js`

`resolveWorkspace(organizations, slug) → { org, domain }` is the **one** place a URL slug is
turned into data. It matches, in order: a domain's own `slug` (→ that domain); then the org's
`slug`/`id` (→ `{ org, domain: null }` — org-level, i.e. all domains). `domain === null` means
"org-level", **not** "unknown" — an unknown slug returns `{ null, null }`. Callers that need a
concrete domain (the settings page) fall back to `defaultDomainOf(org)`.

Consumers:
- `InboxPage` — derives `currentOrg` + the domain filter from the path slug.
- `UnifiedInboxView` — resolves the org (and uses its **public id** as `orgId`, since a
  non-default domain slug matches neither an org key nor an org slug on the API).
- `ChromeBar` — resolves the **org's primary slug** for org-level nav targets (see below).
- `CommandCenterPage` — hardened org lookup.

### API — `base_controller.rb`

`scope.find_by(key: org_id) || scope.find_by!(slug: org_id)` — the `:org_id` path segment
accepts an **org public key or an org slug**. It does **not** resolve a non-default *domain*
slug, which is why the client resolves domain slugs itself and passes the org's public id /
default slug + a separate `?domain=dom_…` filter to MX endpoints.

## The navigation core (don't reinvent per-feature)

Three pieces, all slug/path based — the domain rides in the existing `orgSlug` slot, so none of
them needed to learn about domains:

- **`parseUrl(pathname, search)`** (`routes.jsx`) — URL → `{ page, orgSlug, accountKey, unified,
  … }`. `unified` distinguishes `/:slug/mail` (unified) from `/:slug/mail/inbox` (single view);
  both have `accountKey=null`, so without the flag history can't tell them apart.
- **`navigationStore.buildUrl()`** — state → URL. `unified ? /:slug/mail : /:slug/mail/inbox`.
  **`conversationId` rides the `?c=conv_…` query param** (like `?from=`/`?to=`/`?space=`), so a
  refresh reopens the selected email instead of dropping back to the list. Selection uses
  `replace` + `replaceStack`, so the address bar updates without pushing a browser-history entry
  (the back button still isn't polluted). Deselecting drops `?c=`.
- **`navigationStore.syncFromUrl()`** — URL → state (via `NavigationSync`), keeping the store and
  the router in lock-step for back/forward.

## Tabs ↔ URLs (`ChromeBar`)

| Tab | Navigates to | Active when |
|-----|--------------|-------------|
| Unified cube | `/:orgPrimarySlug/mail` | mail route, no `/inbox`, no external account |
| MX domain tab | `/:domainSlug/mail/inbox` | path is `/…/mail/inbox` and its slug === the tab's `domainSlug` |
| External account tab | `/:orgPrimarySlug/mail/account/:key` | `accountKey` matches |
| Calendar / Explorer / Spaces | `/:orgPrimarySlug/…` | tab key matches |

Each MX tab (`useAccounts`) carries **`domainSlug`** (for the path) alongside `domainKey` (the
`dom_…` id sent to the API as `?domain=`) and `orgSlug`. The single-domain/legacy fallback has no
`domainSlug` → its tab routes to the org's unified inbox instead of a domain path.

Both the **unified** view (`UnifiedInboxView`) and the **single-domain** view (`InboxPage`)
render the *same* per-domain tab strip — both pass `useAccounts`' `allAccounts` to `ChromeBar`.
(`useUnifiedInbox` exposes a separate per-**org** account shape used only for the unified body's
channel filter, never for the tabs — mixing them collapsed the domain tabs into one "org" tab.)

> **The `dom_…`-key-as-org-id trap.** A per-domain account's `key` is a `dom_…` **domain** id,
> not an org id — passing it to an org-scoped endpoint (`/orgs/:id/…`) 404s. Anything iterating
> the per-domain `allAccounts` and calling an org API must key on the org (`a.orgSlug`), not
> `a.key`. Current call sites, both handled:
> - **Unread badges** (`useChannelUnreadCounts`) — fetch the org pool by `orgSlug` narrowed with
>   `?domain=domainKey`; the badge store key stays the account's own `key`.
> - **Explorer unified graph** (`useExplorerGraph`) — `getMailboxStats` is org-level, so it
>   fetches once per org by `orgSlug` (deduped across that org's domain tabs).
>
> The **unified inbox** (`useUnifiedInbox`) sidesteps this by using a separate per-**org** account
> shape (`key: org.slug`) for its own data + actions — never mix it with the per-domain tab list.

## Org-level vs domain-level — the golden rule

**A domain slug must never leak into a non-mail, org-level route.** Settings, Calendar,
Explorer, Search, and the unified cube are org-level; they target **`orgPrimarySlug`** (the
org's canonical slug), computed via `resolveWorkspace(...).org.slug`. Only `/:slug/mail/inbox`
(and its filtered variants) may carry a specific domain slug.

The **Space filter overrides the domain filter**: Spaces are an org-wide AI-classification
concept spanning all domains, so `/:slug/mail/inbox?space=…` shows the whole org pool, not one
domain (`InboxPage`: `domainFilter = (routeAccountKey || spaceFilter) ? null : slugDomain?.id`).

## Console (`/console`) domain cards

`useAdminData` builds one row per domain. Each row carries **both**:
- `slug` = the **org** slug — for org-level ops (`getOrg`, org name/logo).
- `domainSlug` = the **domain's own** slug — for the "Open" → `/:domainSlug/mail/inbox` link
  **and** the gear → `/console/domains/:domainSlug` per-domain settings page.

## Per-domain settings (`/console/domains/:slug`)

`DomainSettingsPage` takes the **domain slug** and resolves it to `(org, domain)` via
`resolveWorkspace(organizations, slug)` — no fetch; the session org list already carries every
domain (icon/status/dns/e2ee) through `DomainSerializer`. Back-compat: an **org** slug resolves
to the org's default domain. The model keeps `key`/`orgKey` = org id (org-scoped API base) and
`domainKey` = the specific domain.

What is **per-domain** vs **org-level** (domains have no display-name / logo column — those are
org brand):

| Tab / field | Scope | Endpoint |
|-------------|-------|----------|
| Square icon | **per-domain** (all domains) | `POST /orgs/:org/domains/:domainKey/icon` |
| DNS records + Verify | **per-domain** | `…/domains/:domainKey/dns[/verify]` |
| Deliverability, Encryption | **per-domain** | `…/domains/:domainKey/e2ee`, … |
| Remove domain (Advanced) | **per-domain** | `DELETE /orgs/:org/domains/:domainKey` |
| Team | org-scoped (members are org entities with per-domain grants) | `…/members` |
| Organization name + Company logo | **org-level** — editable only on the **default** domain | `PATCH /orgs/:org`, `…/logo` |

> The danger-zone "Remove domain" now deletes **only that domain** (`removeDomain`); it previously
> called `deleteOrg`, which would have wiped the entire org and every sibling domain.

## Branding (icons & logos)

Two distinct brand assets, resolved with a **fallback chain** so a tab/card always shows
something:

- **Square icon** — the per-domain workspace-tab glyph. Resolution (in `useAccounts` for tabs,
  `useAdminData` for console cards, both mirrored):
  `domain.icon_url` → *(default domain only)* `org.icon_url` → **name initials**
  (`initialsDataUri`). A sibling domain therefore never inherits the org/default icon — it falls
  through to its own initials. Uploaded per-domain via `POST /orgs/:org/domains/:domainKey/icon`
  (bytes sniffed, SVG rejected — see `ImageAssets`).
- **Company logo** — the full brand logo for the console + sign-in. **Org-level**, one per org;
  editable only on the default domain's settings.

## Two sync modes (never conflate)

- **MX** (this doc) — inbox2-hosted domains, synced against the Rails API / Postgres.
- **External channels** (Gmail / Office365 / IMAP) — fully client-side SQLite via the SyncChannel
  pattern; they **never touch the API** and are addressed by `accountKey`, not a domain slug.
