# Inbox2 — Full Feature Specification

**Version:** 1.12 (draft, fully numbered)
**Status:** For review
**Scope:** Functional feature spec, plus an indicative architecture section (section 16). All architecture technology choices are now settled; section 16.6 is retired.

---

## 0. How to read this document

Every feature item has a stable number (e.g. `7.3.5`). Use these numbers to give changes — for example: "remove 9.2", "move 8.3.4 to P1", "reword 3.3.2". Numbers are stable; if an item is removed, its number is retired rather than reused.

Each item carries a release priority:

- **P0** — Must ship in v1. Without it the product is not credible.
- **P1** — Fast follow. Expected by most buyers within the first months.
- **P2** — Later. Valuable but not blocking initial launch.

### 0.1 Test-coverage requirement (binding)

Every feature item in this specification MUST be covered by automated tests. The project target is **> 95% coverage of spec items** — measured as the proportion of numbered feature items that have at least one corresponding automated test exercising them, not merely line coverage. This applies across all components (mail-handling, API, clients). Section 17 defines how coverage is tracked. An item without a corresponding test is treated as incomplete regardless of whether code exists.

### 0.2 Change history

**v1.2** — Username/password signup; email verification removed; passkeys added; one-account-many-domains with each domain its own organization; Cloudflare one-click DNS; RFC 5322 threading; "Archived" inbox-zero view; admin-controlled view creation; removed SLA, team chat, analytics.

**v1.3** — Researched anti-spam strategy with optional LLM screening (11.1); agentic users (5.5); route-to-agent action (7.3.13); agent & MCP interface (14); indicative architecture (16).

**v1.4** — Standard Rails JSON API (Action Cable enabled); Go for MX/SMTP; Rspamd as a separate Docker service; S3-compatible attachment storage; binding > 95% test-coverage requirement (0.1, section 17).

**v1.5** — Queue resolved to NATS with JetStream; initial S3-compatible store resolved to Garage; section 16.6 (open architecture questions) retired.

**v1.6** — Section 13 restructured into concrete plans (Free; Paid USD 19/mo flat); flat-per-account pricing superseded the earlier per-domain wording (anti-seat principle retained); new section 11.5 mail size limit; downgrade handling added.

**v1.7** — Anti-spam became Rspamd-only (LLM screening layer 11.1.8–11.1.9 retired); mail size limit became plan-dependent (20 MB Free / 100 MB paid).

**v1.8** — Full keyboard operability added as an explicit P0 guarantee (12.1.10); command palette promoted P1 → P0.

**v1.9** — Full-text search committed to PostgreSQL built-in FTS; new section 16.7 offline desktop sync (PowerSync recommended; Yjs assessed and rejected).

**v1.10:**
- **Section 17** — Restructured into subsections: 17.1 spec-item coverage (was the flat 17.1–17.7), new **17.2 MX & SMTP component test suite** (full Go suites, a curated email test corpus, email-injection rake tasks, an outbound sink, conformance tests), new **17.3 seed data** (Rails seeds for the app, composable with the MX injection tasks), new **17.4 performance suites** (MX and SMTP throughput/latency load testing).
- **New section 18 — Email standards.** Researched and enumerated the standards the MX/SMTP components must support, matching what Gmail / Yahoo / Microsoft require and support in 2026: transport & format (SMTP 5321, IMF 5322, MIME, STARTTLS, SIZE), authentication (SPF, DKIM, DMARC, ARC, From-alignment), transport-security policy (MTA-STS, TLS-RPT; MTA-DANE deprioritised), and deliverability (PTR/rDNS, List-Unsubscribe, DSN bounces).
- **Section 19** — Former release summary (section 18) renumbered to 19.

**v1.11:**
- **New section 20 — Outbound delivery channels & tracking.** Admins can configure external SMTP relays or Amazon SES as delivery channels instead of (or alongside) Inbox2's own outbound infrastructure. Every outbound message carries a delivery status (Queued → Delivered / Failed / Bounced) with per-attempt logging, automatic retry, bounce processing, and per-channel delivery statistics.
- **Section 19** — Release summary updated to include delivery channels and tracking.

**v1.12 (this version, 2026-11-09):**
- **Section 13** — the three tiers as built replace the single flat paid plan (13.1.2, 13.1.3), prices in euros, Disk storage and the 25 MB send cap stated; annual billing (13.1.5), the trial (13.2.2) and the failed-payment fallback (13.2.4) are specified as decided on 2026-11-09. Payments run through Stripe's hosted checkout and customer portal.
- **Section 16.7** rewritten to the sync that was built: a local mirror on every native client (not the desktop alone), inbox2's own pull, backfill and reconcile protocol in the Rust core in place of the PowerSync recommendation of v1.9, queued actions replayed against the REST endpoints in place of a row push, and sealed mail in the mirror (new 16.7.7).

---

## 1. Product summary

**1.1** Inbox2 is domain-based team email. All mail sent to a connected domain is captured into a single shared pool. Instead of mailboxes hard-linked to individual people, the whole team sees one stream and each member defines personal filtered views over it.

**1.2** Routing rules push patterns to specific members, to agentic (AI) users, or to external HTTP endpoints.

**1.3** The interface behaves like a familiar email client — threads, message view, composer — with collaboration layered on top (assignment, tags, private notes, statuses).

**1.4** The licensing model is flat-per-account, not per-seat. Adding team members never increases cost (see section 13).

**1.5** Target user: entrepreneurs and small businesses who want professional domain email and light collaboration without paying per-seat for Google Workspace, Microsoft 365, or a helpdesk tool. A common pattern is one entrepreneur running several separate ventures, each on its own domain, kept segregated.

**1.6** Feature philosophy: competitive research shows routing, internal notes, tagging, assignment, and collision detection are *table stakes* — every shared-inbox and helpdesk tool ships them. They are included here as expected baseline, not differentiators. The genuine differentiators are (a) the unified pool plus user-defined views architecture, (b) flat, anti-seat pricing — unlimited domains and collaborators for one low flat fee — and (c) first-class agentic users — routing mail to AI agents as naturally as to people. The spec is sequenced so v1 ships the baseline credibly and defers heavier machinery.

---

## 2. Accounts, domains & onboarding

### 2.1 Signup & authentication

| # | Item | Priority |
|---|------|----------|
| 2.1.1 | Username + password signup for the account owner. Email is deliberately *not* the signup identifier: domains are added later and the owner may be mid-migration off an existing email domain, so a working email address cannot be assumed at signup. | P0 |
| 2.1.2 | *(Retired — email verification not required; trust is established via domain verification, 2.3.x.)* | — |
| 2.1.3 | Login, logout, and password reset. | P0 |
| 2.1.4 | Session management — view active sessions, sign out of all. | P0 |
| 2.1.5 | Strong second factors: passkeys (WebAuthn) and TOTP authenticator apps. | P1 |
| 2.1.6 | Social / SSO login (Google, Microsoft) as an *alternative* sign-in, not a dependency. | P1 |
| 2.1.7 | SAML SSO for larger customers. | P2 |
| 2.1.8 | Collect a billing/contact email separately from signup, so Inbox2 can reach the owner for billing and account notices. This must be an address Inbox2 does *not* host — a safeguard against the catch-22 where a billing failure on an Inbox2-hosted domain would block the very mail needed to fix it. Prompt at signup; warn if an Inbox2-hosted address is later used. | P0 |

### 2.2 Accounts, domains & organizations

The model: **one account → many domains. Each domain is its own organization** — its own pool, members, rules, tags, and views, fully segregated from other domains on the same account.

| # | Item | Priority |
|---|------|----------|
| 2.2.1 | One account can hold N domains; each domain is an independent organization with its own pool, members, rules, tags, statuses, and views. Data is segregated between organizations. | P0 |
| 2.2.2 | Account-level settings: account owner identity, billing details, default time zone and language. | P0 |
| 2.2.3 | Per-organization settings: organization name, time zone, language (inherit account defaults unless overridden). | P0 |
| 2.2.4 | Account owner role with full control across all organizations on the account. | P0 |
| 2.2.5 | Alias domains — a secondary domain attached to an existing organization so mail to either domain feeds the same pool. | P1 |
| 2.2.6 | Transfer ownership of the account, or of an individual organization, to another member. | P1 |
| 2.2.7 | A switcher to move between organizations; an at-a-glance overview of all organizations on the account. | P1 |

### 2.3 Connecting a domain

| # | Item | Priority |
|---|------|----------|
| 2.3.1 | Add a domain via a guided wizard; adding a domain creates its organization. | P0 |
| 2.3.2 | DNS verification — product generates required records (verification, MX, SPF/DKIM/DMARC) with a live re-check button and per-record pass/fail status. Includes a **one-click Cloudflare integration**: the owner authorizes via a scoped Cloudflare API token and Inbox2 writes the records automatically. | P0 |
| 2.3.3 | Clear per-domain status indicators: *Pending DNS*, *Verified*, *Receiving mail*, *Error*. | P0 |
| 2.3.4 | Connect multiple domains under one account; each becomes its own organization. | P0 |
| 2.3.5 | Copy-paste DNS snippets formatted for common registrars, plus plain-text fallback (for non-Cloudflare DNS). | P1 |
| 2.3.6 | Ongoing domain health monitoring with alerts if MX/SPF/DKIM/DMARC break. | P1 |
| 2.3.7 | Sending-domain setup — DKIM signing so outbound replies authenticate. | P1 |
| 2.3.8 | One-click DNS integrations for additional registrars/DNS providers beyond Cloudflare. | P2 |
| 2.3.9 | Subdomain support (e.g. `support.acme.com`). | P2 |

### 2.4 Onboarding flow

| # | Item | Priority |
|---|------|----------|
| 2.4.1 | First-run checklist: create account → add domain → verify DNS → invite members → confirm mail arriving → create first routing rule. | P0 |
| 2.4.2 | Test/diagnostic tool: send a test email to the domain and watch it land in the pool. | P0 |
| 2.4.3 | Sample/seed data or an interactive tour so an empty pool isn't a dead end. | P1 |
| 2.4.4 | Import of historical mail (see 11.2). | P1 |

---

## 3. The unified pool & inbox model

The core architectural differentiator. Scope note: "the pool" is per-organization (per-domain); there is no cross-organization pool.

### 3.1 The pool

| # | Item | Priority |
|---|------|----------|
| 3.1.1 | Every message received at a verified domain lands in that organization's unified pool, regardless of recipient address (`sales@`, `info@`, typos — all captured). | P0 |
| 3.1.2 | Messages are grouped into conversations/threads by standard threading (References / In-Reply-To headers, with subject-based fallback). | P0 |
| 3.1.3 | Threading and conversation identity rely on portable RFC 5322 headers — `Message-ID`, `In-Reply-To`, `References`. Provider-internal identifiers (e.g. Gmail's `X-GM-THRID`) are not applicable once Inbox2 is the MX of record. | P0 |
| 3.1.4 | A conversation carries metadata: status, assignees, tags, member access, original recipient address(es), and the routing rules that touched it. | P0 |
| 3.1.5 | The pool is the single source of truth. Views, filters, and routing never *move* mail out of the pool — they only change what a person sees and what metadata is attached. | P0 |

### 3.2 Default views

| # | Item | Priority |
|---|------|----------|
| 3.2.1 | **All Mail** — the entire pool (subject to access permissions). | P0 |
| 3.2.2 | **Assigned to me** — conversations where the member is an assignee. | P0 |
| 3.2.3 | **Mentioned / My notes** — conversations where the member was @mentioned in a private note. | P0 |
| 3.2.4 | **Unassigned** — conversations with no assignee. | P0 |
| 3.2.5 | **Sent** — outbound messages. | P0 |
| 3.2.6 | **Drafts** — saved unsent drafts. | P0 |
| 3.2.7 | **Snoozed** — conversations hidden until a chosen time. | P1 |
| 3.2.8 | **Archived** — conversations cleared from the active inbox, supporting an inbox-zero workflow. | P1 |
| 3.2.9 | **Spam** and **Trash**. | P1 |

### 3.3 User-defined views (saved filters) — KEY DIFFERENTIATOR

| # | Item | Priority |
|---|------|----------|
| 3.3.1 | Members can create personal saved views by defining filter criteria over the pool. An admin chooses, during domain setup, whether members may define their own views or whether view creation is admin-only. | P0 |
| 3.3.2 | Filter criteria include at minimum: recipient address (`to:`/`cc:`), sender, subject contains, body contains, tag, status, assignee, has-attachment, date range, and the routing rule that matched. | P0 |
| 3.3.3 | Combine criteria with AND logic. | P0 |
| 3.3.4 | Combine criteria with OR logic and grouped conditions. | P1 |
| 3.3.5 | Saved views appear in the member's own sidebar, named and reorderable. | P0 |
| 3.3.6 | Shared/team views — a view definition published to the whole team or selected members, managed by admins. | P1 |
| 3.3.7 | Unread counts / badges on each view. | P1 |
| 3.3.8 | "Smart" suggested views based on the member's activity. | P2 |

### 3.4 Conversation list

| # | Item | Priority |
|---|------|----------|
| 3.4.1 | List shows sender, subject, snippet, timestamp, attachment indicator, tag chips, assignee avatar(s), status, and unread state. | P0 |
| 3.4.2 | Sort by newest, oldest, or last-activity. | P0 |
| 3.4.3 | Bulk select with bulk actions (assign, tag, status change, archive, delete, mark read/unread). | P0 |
| 3.4.4 | Unread vs. read state, plus "seen by" awareness within the team. | P0 |
| 3.4.5 | List density options (compact / comfortable). | P1 |
| 3.4.6 | Pagination or infinite scroll tuned for large pools. | P1 |

---

## 4. Reading & conversation view

### 4.1 Message rendering

| # | Item | Priority |
|---|------|----------|
| 4.1.1 | Full thread view; each message expandable/collapsible, quoted history behind a "show trimmed content" toggle. | P0 |
| 4.1.2 | Safe HTML email rendering with image proxying and remote-content blocking by default ("load images" prompt). | P0 |
| 4.1.3 | Plain-text fallback rendering. | P0 |
| 4.1.4 | Attachment list per message: filename, type icon, size, download, inline preview for images and PDFs. | P0 |
| 4.1.5 | Full original headers viewable on demand; "view original / raw source". | P0 |
| 4.1.6 | Print / export a conversation to PDF. | P1 |
| 4.1.7 | Link-safety warnings for suspicious URLs. | P1 |

### 4.2 Conversation actions

| # | Item | Priority |
|---|------|----------|
| 4.2.1 | Reply, Reply All, Forward. | P0 |
| 4.2.2 | Change status (see 6.1). | P0 |
| 4.2.3 | Assign / unassign (see 5.2). | P0 |
| 4.2.4 | Add/remove tags (see 6.2). | P0 |
| 4.2.5 | Grant/revoke member access via tagging (see 5.3). | P0 |
| 4.2.6 | Archive, delete, mark spam, mark read/unread. | P0 |
| 4.2.7 | Snooze until a chosen time/date. | P1 |
| 4.2.8 | Merge two conversations; split a message into a new conversation. | P1 |
| 4.2.9 | Move/link a conversation to a different domain context if mis-threaded. | P1 |
| 4.2.10 | Convert a conversation to a task with a due date. | P2 |

### 4.3 Context sidebar

| # | Item | Priority |
|---|------|----------|
| 4.3.1 | Contact panel: sender's name, address, and full history of prior conversations with that contact across the pool. | P0 |
| 4.3.2 | Conversation properties panel: original recipient address, matched routing rules, status, tags, assignees, members with access. | P0 |
| 4.3.3 | Attachment gallery for the whole conversation. | P1 |
| 4.3.4 | Activity log — inline timeline of events (assignment, tag, status, rule actions, snooze/unsnooze, access changes, agent actions). | P1 |
| 4.3.5 | Lightweight contact CRM fields (company, phone, notes) editable inline. | P2 |

---

## 5. Team members, assignment & access

Scope note: members are added per organization (per domain). A person may be a member of several organizations on the same account. Members may be human users (5.1–5.4) or agentic users (5.5).

### 5.1 Inviting & managing members

| # | Item | Priority |
|---|------|----------|
| 5.1.1 | Invite team members by email; invitee sets their own username and password. | P0 |
| 5.1.2 | Unlimited members — adding members never affects price; surfaced explicitly in-product. | P0 |
| 5.1.3 | Member list with status (invited / active / disabled) and type (human / agent). | P0 |
| 5.1.4 | Remove or disable a member; reassign or release their conversations on removal. | P0 |
| 5.1.5 | Roles: Owner, Admin, Member. Owner/Admin manage domains, billing, members, rules, and shared views; Members work the inbox. | P0 |
| 5.1.6 | Restricted **Limited Member** role — sees only conversations explicitly shared with them or matched by rule. | P1 |
| 5.1.7 | Per-organization membership — a person can belong to some organizations on the account and not others. | P1 |
| 5.1.8 | Custom roles with granular permissions. | P2 |
| 5.1.9 | Member groups / teams as assignable units. | P2 |

### 5.2 Assignment

| # | Item | Priority |
|---|------|----------|
| 5.2.1 | Assign a conversation to one or more members (human or agent). | P0 |
| 5.2.2 | Assignment visible in the list and conversation view; assignees notified. | P0 |
| 5.2.3 | Unassign / reassign; assignment history kept in the activity log. | P0 |
| 5.2.4 | Round-robin / load-balanced auto-assignment as a routing-rule action. | P1 |
| 5.2.5 | Out-of-office / unavailable flag so auto-assignment skips a member. | P1 |
| 5.2.6 | Assignment by member group with claim-from-pool behavior. | P2 |

### 5.3 Conversation access via tagging members

| # | Item | Priority |
|---|------|----------|
| 5.3.1 | Tag a team member onto a conversation to grant them access to it. Distinct from assignment: access ≠ ownership. | P0 |
| 5.3.2 | Tagged members can view and act on the conversation and are notified. | P0 |
| 5.3.3 | Remove a member's access; access changes recorded in the activity log. | P0 |
| 5.3.4 | Interaction with the Limited Member role — tagging is the primary way limited members receive work. | P1 |

### 5.4 Collision detection & presence

| # | Item | Priority |
|---|------|----------|
| 5.4.1 | Real-time indicator showing when another member is viewing the same conversation. Delivered over Action Cable (16.3.2). | P0 |
| 5.4.2 | "Currently replying" indicator to prevent duplicate replies. | P0 |
| 5.4.3 | Typing indicators inside the composer. | P1 |
| 5.4.4 | Real-time collaborative draft editing (multiple cursors on one reply). | P2 |

### 5.5 Agentic users — DIFFERENTIATOR

An agentic user is a member that is an AI agent rather than a person. Routing rules and assignment treat agents and humans uniformly: an agent can own conversations, be granted access, and receive a routed feed — but instead of logging into the web UI, it consumes its feed and acts through the API and MCP interface (section 14).

| # | Item | Priority |
|---|------|----------|
| 5.5.1 | Create an agentic user within an organization. It appears in the member list, typed as *agent*, and can be assigned conversations and granted access exactly as a human member. | P1 |
| 5.5.2 | An agentic user authenticates via a scoped API credential (not username/password); it has no web-UI session. | P1 |
| 5.5.3 | Each agentic user has a **routed feed** — the stream of conversations routed or assigned to it — readable over the API and exposed via MCP (see 14.2, 14.3). | P1 |
| 5.5.4 | Per-agent permission scope: which actions it may take (read, reply, tag, set status, assign, grant access) and whether replies require human approval before sending. | P1 |
| 5.5.5 | Agent actions are attributed to the agent in the activity log and visually distinguished in the conversation timeline. | P1 |
| 5.5.6 | A human "supervisor" can be designated per agent to receive notifications of agent activity and handle escalations. | P1 |
| 5.5.7 | Approval queue — when an agent's reply requires human sign-off (5.5.4), it is held as a shared draft (8.1.10) for a human to review, edit, and send. | P1 |
| 5.5.8 | Rate / spend limits per agent (message volume, and where applicable LLM token budget) with alerting. | P2 |
| 5.5.9 | Agent run log — a per-agent record of inputs consumed, actions taken, and outcomes, for debugging and audit. | P2 |
| 5.5.10 | Prompt-injection safeguards for agentic users — inbound mail is untrusted content and may contain instructions targeting the agent (see 11.4); agent tooling must treat message bodies as data, not instructions. | P1 |

---

## 6. Conversation organization

### 6.1 Statuses

| # | Item | Priority |
|---|------|----------|
| 6.1.1 | Core lifecycle statuses: Open, Snoozed/Pending, Archived (deliberately simple for the SMB audience; supports inbox-zero). | P0 |
| 6.1.2 | Status visible in list and view; status changes logged. | P0 |
| 6.1.3 | A "Waiting on customer" / on-hold status. | P1 |
| 6.1.4 | Custom statuses defined per organization. | P2 |

### 6.2 Tags / labels

| # | Item | Priority |
|---|------|----------|
| 6.2.1 | Create, rename, color, and delete tags at the organization level. | P0 |
| 6.2.2 | Apply multiple tags per conversation; tags usable as filter criteria and rule conditions/actions. | P0 |
| 6.2.3 | Tag groups / categories for organization. | P1 |
| 6.2.4 | Auto-tagging via rules based on content (see section 7). | P2 |

### 6.3 Search

Full-text search is provided by **PostgreSQL's built-in full-text search** — no separate search service. This keeps the stack lean (the no-extra-infrastructure principle) and reuses the primary datastore (16.3.1).

| # | Item | Priority |
|---|------|----------|
| 6.3.1 | Full-text search across the pool: subject, body, sender, recipient, attachment filenames. Implemented with PostgreSQL full-text search (`tsvector`/`tsquery`, indexed). | P0 |
| 6.3.2 | Search scoped to a view, an organization, or all organizations on the account. Always tenant-scoped (results never cross organizations the member cannot access). | P0 |
| 6.3.3 | Search operators (`from:`, `to:`, `subject:`, `has:attachment`, `tag:`, `status:`, `before:`/`after:`). | P1 |
| 6.3.4 | Save a search as a view. | P1 |
| 6.3.5 | Search inside attachment contents (PDF/doc text) — extracted text indexed into the same Postgres full-text index. | P2 |
| 6.3.6 | Spelling correction on a zero-hit search: the empty state offers "Did you mean *emirates*?" — offered, never auto-run, so what the member typed is never silently replaced. Candidate words come from their own mail, not a dictionary — Postgres trigrams (`pg_trgm`) for pooled mail, the FTS5 `fts5vocab` term index for local channels — so a suggestion is always something they can actually find. Tenant-scoped like the search itself. | P1 |

---

## 7. Routing rules & automation

The spec's central workflow feature. Rules are defined per organization.

### 7.1 Rule builder

| # | Item | Priority |
|---|------|----------|
| 7.1.1 | Visual rule builder: IF conditions THEN actions. | P0 |
| 7.1.2 | A rule has: name, on/off toggle, order/priority, conditions, actions. | P0 |
| 7.1.3 | Rules run on inbound messages as they enter the pool. | P0 |
| 7.1.4 | Rules can also run on conversation events (status change, tag added, reply sent). | P1 |
| 7.1.5 | Per-rule run log showing which messages matched and what the rule did. | P1 |
| 7.1.6 | Test a rule against recent pool messages before enabling it ("dry run"). | P1 |

### 7.2 Conditions

| # | Item | Priority |
|---|------|----------|
| 7.2.1 | Recipient address — exact (`sales@`) or pattern/wildcard. | P0 |
| 7.2.2 | Sender address / sender domain. | P0 |
| 7.2.3 | Subject contains / equals / matches. | P0 |
| 7.2.4 | Body contains. | P0 |
| 7.2.5 | Has attachment / attachment type. | P0 |
| 7.2.6 | Domain the mail arrived on (for organizations with alias domains, 2.2.5). | P1 |
| 7.2.7 | Header matching. | P1 |
| 7.2.8 | Regex matching on subject/body. | P1 |
| 7.2.9 | Combine conditions with AND/OR and grouping. | P1 |
| 7.2.10 | Spam score / classification as a condition (from the filtering layer, 11.1). | P1 |

### 7.3 Actions

| # | Item | Priority |
|---|------|----------|
| 7.3.1 | Assign to one or more specific members (covers "sales@ goes to user A and B"). | P0 |
| 7.3.2 | Grant conversation access to one or more members (covers "everything with XXX in subject goes to user A and C" when those users need access, not ownership). | P0 |
| 7.3.3 | Add tag(s). | P0 |
| 7.3.4 | Set status. | P0 |
| 7.3.5 | POST the message to an external HTTP endpoint / webhook (covers "finance@ is posted to HTTP API XXX"); structured JSON payload with headers, parsed body, attachment metadata. | P0 |
| 7.3.6 | Round-robin assignment across a set of members. | P1 |
| 7.3.7 | Auto-reply / send a canned response. | P1 |
| 7.3.8 | Forward to an external email address. | P1 |
| 7.3.9 | Mark as spam / archive / delete. | P1 |
| 7.3.10 | Snooze. | P1 |
| 7.3.11 | Stop processing further rules ("final" flag). | P2 |
| 7.3.12 | Conditional branching / multi-step rules. | P2 |
| 7.3.13 | Route to an agentic user — deliver the message to an AI agent's routed feed (see 5.5, 14). Functionally an assignment/access action targeting an agent, called out separately because it is a headline use case. | P1 |

### 7.4 Webhook delivery (the HTTP-API action, in detail)

| # | Item | Priority |
|---|------|----------|
| 7.4.1 | Configurable endpoint URL per rule. | P0 |
| 7.4.2 | JSON payload with message data and attachment references. | P0 |
| 7.4.3 | Delivery log per webhook: HTTP status, response, timestamp. | P1 |
| 7.4.4 | Automatic retry with backoff on failure; alert on repeated failure. | P1 |
| 7.4.5 | Signing secret so the receiver can verify authenticity. | P1 |
| 7.4.6 | Custom payload templates / field mapping. | P2 |
| 7.4.7 | Attachment-content inclusion (base64) vs. reference URL as a per-rule choice. | P2 |

---

## 8. Composing & sending

### 8.1 Composer

| # | Item | Priority |
|---|------|----------|
| 8.1.1 | Rich-text composer: bold, italic, lists, links, headings. | P0 |
| 8.1.2 | Send from any address on a verified domain; choose the From address per message. | P0 |
| 8.1.3 | Attachments with drag-and-drop; inline images. | P0 |
| 8.1.4 | CC / BCC. | P0 |
| 8.1.5 | Save draft automatically; resume drafts from the Drafts view. | P0 |
| 8.1.6 | Reply quoting with collapsible history. | P0 |
| 8.1.7 | Signatures — personal and organization-level, HTML supported, auto-applied per From address. | P1 |
| 8.1.8 | Send later / scheduled send. | P1 |
| 8.1.9 | Undo send (short cancellation window). | P1 |
| 8.1.10 | Shared draft — a draft visible to teammates for review before sending; also the holding mechanism for the agent approval queue (5.5.7). | P1 |
| 8.1.11 | Real-time collaborative drafting. | P2 |

### 8.2 Canned responses / templates

| # | Item | Priority |
|---|------|----------|
| 8.2.1 | Create, organize, and insert reusable reply templates. | P1 |
| 8.2.2 | Personal templates and shared org-wide templates. | P1 |
| 8.2.3 | Placeholder variables (contact name, original recipient address, etc.). | P1 |
| 8.2.4 | Template usage analytics. | P2 |

---

## 9. Collaboration

### 9.1 Private notes

| # | Item | Priority |
|---|------|----------|
| 9.1.1 | Add internal notes to a conversation, ticketing-style; never visible to the external sender. | P0 |
| 9.1.2 | Notes are visually distinct from email messages in the thread. | P0 |
| 9.1.3 | @mention a teammate in a note to notify them and grant/confirm access. | P0 |
| 9.1.4 | Notes support basic formatting and attachments. | P0 |
| 9.1.5 | Notes appear in the conversation timeline in chronological context. | P0 |
| 9.1.6 | Edit / delete own notes; note edit history. | P1 |
| 9.1.7 | Reactions / threaded replies on notes. | P2 |

---

## 10. Notifications

| # | Item | Priority |
|---|------|----------|
| 10.1 | In-app notification center: assignments, @mentions, access grants, replies on conversations the member is on, agent escalations. | P0 |
| 10.2 | Email notifications for the same events, with per-event toggles. | P0 |
| 10.3 | Per-member notification preferences. | P0 |
| 10.4 | Browser push / desktop notifications. | P1 |
| 10.5 | Digest mode (batched notifications) to reduce noise. | P1 |
| 10.6 | Mobile push (if/when mobile apps exist). | P1 |
| 10.7 | Notification routing rules (e.g. only notify for tagged-as-urgent). | P2 |

---

## 11. Spam, security & mail handling

### 11.1 Anti-spam strategy

**Research context (2026).** A majority of spam and over 80% of analysed phishing now contains AI-generated content — unique per-send, grammatically clean, able to mimic a trusted contact's style — which defeats fixed keyword heuristics and strains classic Bayesian filters. The current open-source consensus engine is **Rspamd** (fast C core, Bayesian + DNSBL/URIBL + fuzzy hashing + a self-training neural network module + built-in DKIM/SPF/DMARC). Inbox2's catch-all pool *increases* spam exposure. Inbox2's anti-spam approach is **Rspamd-based, not LLM-based** — Rspamd's own neural module learns from traffic and handles AI-generated spam without the per-message cost and latency of an external LLM, which keeps anti-spam compatible with the flat pricing model (section 13). The pipeline is layered: cheap deterministic checks on the critical delivery path, then Rspamd scoring.

| # | Item | Priority |
|---|------|----------|
| 11.1.1 | Layer 1 — protocol & reputation checks on the critical path: SPF/DKIM/DMARC validation, DNSBL/URIBL lookups, greylisting, connection rate-limiting. Fast, deterministic, runs before mail enters the pool. | P0 |
| 11.1.2 | Layer 2 — Rspamd produces a spam score per message (Bayesian, DNSBL/URIBL, fuzzy hashing, and its self-training neural module). Rspamd runs as a separate service (16.5.3); the score is stored on the message and usable as a routing-rule condition (7.2.10). Rspamd is the complete spam engine — there is no separate LLM screening layer. | P0 |
| 11.1.3 | Dedicated Spam view; mark as spam / not spam, feeding Rspamd's training. | P0 |
| 11.1.4 | Block list — sender addresses or domains routed straight to spam or rejected. | P0 |
| 11.1.5 | Allow list / trusted senders. | P1 |
| 11.1.6 | Adjustable spam aggressiveness per organization. | P1 |
| 11.1.7 | Optional "structured aliases only" mode — reject mail to addresses not matched by any routing rule, to tame catch-all spam volume. | P1 |
| 11.1.8 | *(Retired — LLM-based screening dropped; Rspamd's neural module covers AI-generated spam without per-message LLM cost.)* | — |
| 11.1.9 | *(Retired — see 11.1.8.)* | — |
| 11.1.10 | Greylisting / rate-limiting fine-tuning controls exposed to admins. | P2 |
| 11.1.11 | Rspamd's neural module is trained and tuned for AI-generated-content patterns as an additional scoring input. | P2 |

### 11.2 Mail import & migration

| # | Item | Priority |
|---|------|----------|
| 11.2.1 | Import historical mail from an existing mailbox (IMAP) or from standard export files into the pool. | P1 |
| 11.2.2 | Scheduled / ongoing sync from a legacy mailbox during a transition period. | P2 |

### 11.3 Security & compliance

| # | Item | Priority |
|---|------|----------|
| 11.3.1 | Encryption in transit (TLS) for mail; encryption at rest for stored mail and attachments. | P0 |
| 11.3.2 | Audit log of administrative actions (member, rule, domain, agent changes). | P0 |
| 11.3.3 | Data export — export all conversations/mail for an organization. | P1 |
| 11.3.4 | Account / organization deletion with full data removal. | P1 |
| 11.3.5 | GDPR-oriented controls: contact data export and deletion on request. | P1 |
| 11.3.6 | Configurable data-retention policies. | P2 |
| 11.3.7 | Per-conversation or per-tag access restrictions for sensitive mail (e.g. `finance@`). | P2 |

### 11.4 Prompt-injection & AI-content safety

Inbound mail is fully untrusted; because Inbox2 exposes agentic users (5.5), indirect prompt injection — malicious instructions hidden in an email body or HTML, aimed at the AI agent rather than the human — is an explicit threat. (Inbox2 does not use an LLM for spam screening, so the only AI surface exposed to mail content is the agentic-user feature.)

| # | Item | Priority |
|---|------|----------|
| 11.4.1 | All LLM/agent processing treats message content as data, never as instructions; system prompts and tool scopes are isolated from message content. | P1 |
| 11.4.2 | Content sanitisation before AI processing — strip/neutralise hidden HTML, zero-width and off-screen text, and other injection-carrying constructs. | P1 |
| 11.4.3 | Least-privilege agent tool scopes (5.5.4) and human approval on consequential actions (5.5.7) as defence-in-depth. | P1 |
| 11.4.4 | A dedicated injection-detection check on content bound for an LLM/agent, logged per decision. | P2 |

### 11.5 Mail size limits

A hard size cap on individual messages keeps storage requirements modest and predictable. The cap is **plan-dependent** (see section 13).

| # | Item | Priority |
|---|------|----------|
| 11.5.1 | Every email — inbound or outbound, message body plus all attachments combined — has a hard size limit determined by the organization's plan: **20 MB on the Free plan, 100 MB on the paid plan**. | P0 |
| 11.5.2 | The MX inbound component (16.2.1) enforces the applicable per-plan limit at SMTP time: oversized inbound mail is rejected with a standard SMTP size-exceeded response, so it never enters the pool or storage. The MX component resolves the receiving domain's plan to apply the correct limit. | P0 |
| 11.5.3 | The composer and send path enforce the same per-plan limit before an outbound message is accepted; the UI surfaces the active limit and the current message size while composing. | P0 |
| 11.5.4 | Both limits (20 MB / 100 MB) are configurable system constants, so they can be revised later without code changes; these are the launch values. | P0 |

---

## 12. User interface & experience

### 12.1 General

| # | Item | Priority |
|---|------|----------|
| 12.1.1 | Web application that behaves like a familiar email client: sidebar of views, conversation list, conversation/message pane (two- or three-column layout). | P0 |
| 12.1.2 | Dark mode as the primary, default theme. | P0 |
| 12.1.3 | Light mode as a full alternative; theme is per-member and persists. | P0 |
| 12.1.4 | Responsive layout usable on tablet and small screens. | P0 |
| 12.1.5 | Keyboard shortcuts for high-frequency actions (navigate list, reply, assign, tag, archive, change status), with a discoverable shortcut reference. | P0 |
| 12.1.6 | Command palette / quick-action search. | P0 |
| 12.1.7 | Swipe actions on touch devices. | P1 |
| 12.1.8 | Per-member UI preferences (list density, default view, signature). | P1 |
| 12.1.9 | Additional themes beyond the two base ones. | P2 |
| 12.1.10 | **Full keyboard operability** — the entire web (and Tauri desktop) application is navigable and operable using the keyboard alone, with no mouse required. Every screen, view, control, dialog, and navigation path is reachable and actionable by keyboard. This is a hard guarantee, broader than the high-frequency shortcuts in 12.1.5: it covers reaching *every* feature, not only the common ones. The command palette (12.1.6) is the keyboard entry point to any screen or action; visible focus state is required on every interactive element; focus order is logical; and no action is mouse-only. | P0 |

### 12.2 Clients

| # | Item | Priority |
|---|------|----------|
| 12.2.1 | Web client — the primary client; React (see 16.4). | P0 |
| 12.2.2 | Desktop client — the web client packaged via Tauri for macOS/Windows/Linux, with native notifications and an offline mode: a local datastore and sync layer (16.7) let it keep working without connectivity. | P1 |
| 12.2.3 | Mobile-optimized web experience. | P1 |
| 12.2.4 | CLI client — a Python terminal client built on Textual, for keyboard-driven and power users (see 16.4). | P2 |
| 12.2.5 | Native iOS / Android apps with push notifications. | P2 |

### 12.3 Accessibility

| # | Item | Priority |
|---|------|----------|
| 12.3.1 | Keyboard navigability throughout, sufficient contrast in both themes, screen-reader labelling, respect for reduced-motion settings. | P1 |

---

## 13. Billing, plans & licensing

**Pricing model note (v1.6, superseded by the v1.12 note below, kept for history).** Earlier drafts described pricing as strictly "per-domain." The concrete plan structure below supersedes that: the paid plan is a **flat account-level subscription** ($19/month) covering unlimited domains and unlimited collaborators. The original anti-seat principle still holds in full — collaborators are never charged per seat — but pricing is now flat-per-account, not per-domain. Item 13.1 is reworded accordingly and the former per-domain items are reconciled below.

**Pricing model note (v1.12, decided 2026-11-09).** The flat single paid plan of v1.6 is replaced by the three tiers the code has enforced since 2026-06 and the site has shown since 2026-09: Free, Startup and Serial Entrepreneur, priced per organisation per month in euros, excluding VAT. No plan charges per added person, but Startup has a limit of two collaborators, so "never per seat" now means there is no per-person price, not that every paid plan is unlimited.

### 13.1 Plans

| # | Item | Priority |
|---|------|----------|
| 13.1.1 | **Free plan** — 1 domain, 1 collaborator (the account owner), no spam filter, 20 MB mail size limit. Intended as a genuine entry point for someone just starting out. | P0 |
| 13.1.2 | **Paid plans** — **Startup**, EUR 19.99 / month: 2 domains, the owner plus 2 collaborators (only the primary owner's seat is free: a co-owner counts as a collaborator, decided 2026-11-17). **Serial Entrepreneur**, EUR 49.99 / month: unlimited domains and collaborators. Both include Rspamd spam filtering (11.1), AI auto-triage, end-to-end encrypted domains, a 100 MB limit on received mail, and Disk (10 GB and 30 GB for each member). A send stops at 25 MB of attachments on every plan; larger files go out as a Disk link. | P0 |
| 13.1.3 | No plan has a per-person price. The Free plan's single-member cap and Startup's two-collaborator cap are plan limits; the next step up is a tier, not a seat. | P0 |
| 13.1.4 | Plan limits are enforced consistently: the Free plan blocks adding a 2nd domain or a 2nd collaborator, does not run the spam filter, and applies the 20 MB mail size limit (vs 100 MB paid, see 11.5); Startup blocks a 3rd domain and a 3rd collaborator; exceeding a limit prompts an upgrade rather than failing silently. | P0 |
| 13.1.5 | Annual billing on both paid plans at ten times the monthly price (two months free), with a monthly/yearly choice at upgrade and proration on a change during the year. | P1 |

### 13.2 Subscription management

| # | Item | Priority |
|---|------|----------|
| 13.2.1 | Subscription management: view current plan, upgrade/downgrade, payment method, invoices, billing history. | P0 |
| 13.2.2 | Free trial of a paid plan: 14 days, no card asked. At its end the organisation is on the Free plan unless it has subscribed. | P0 |
| 13.2.3 | Usage indicators: domains used, collaborators used, storage used, message volume — shown against the active plan's limits. | P1 |
| 13.2.4 | Billing-failure grace handling — because Inbox2 may host the domain's mail, a payment failure must not immediately cut off mail delivery; provide a grace period and reach the owner via the external billing email (2.1.8). On unresolved failure the account falls back toward Free-plan limits rather than a hard cut-off. Decided 2026-11-09: the payment provider retries for about two weeks while the owner is mailed at the confirmed external address; then Free limits apply, and a domain over the limit keeps receiving mail and becomes read-only instead of being locked. | P0 |
| 13.2.5 | Downgrade handling — if a paid account with multiple domains or collaborators downgrades to Free, define and surface what happens (e.g. the owner chooses which single domain remains active); excess data is retained read-only, not deleted, for a grace window. | P1 |
| 13.2.6 | Per-domain or usage-based add-on purchasing. | P2 |
| 13.2.7 | Agency/reseller billing for accounts managing many client domains. | P2 |
| 13.2.8 | If agent LLM usage carries a metered cost, decide whether it is bundled, an add-on, or pass-through. With flat-rate pricing this is more pressing — flagged, not yet specified. | P1 |

---

## 14. Agent & MCP interface

The programmatic surface. Distinct from the per-rule webhook action (7.3.5), which pushes individual messages out; this section is the API and MCP layer that agentic users (5.5) and external developers consume.

| # | Item | Priority |
|---|------|----------|
| 14.1 | REST API: read conversations and messages, send messages, manage tags/statuses/assignment, read a member's or agent's feed. All responses are JSON (see 16.3.2). | P1 |
| 14.2 | An agentic user's routed feed (5.5.3) is retrievable over the API as a first-class endpoint, with incremental/since-cursor fetching. | P1 |
| 14.3 | **MCP server** — Inbox2 exposes an agent's routed feed and permitted actions as Model Context Protocol tools, so an external AI agent can be wired to its feed with minimal glue. Tool scope is bounded by the agent's permission scope (5.5.4). | P1 |
| 14.4 | Outbound webhooks for events (new conversation, status change, assignment, agent escalation) — distinct from the per-rule webhook action. | P1 |
| 14.5 | API keys / agent credentials with scoped permissions and revocation. | P1 |
| 14.6 | Native integrations (CRM, Slack/Teams notifications, Zapier/Make). | P2 |
| 14.7 | Embeddable/iframe widgets in the conversation sidebar. | P2 |

---

## 15. Explicitly out of scope (for now)

| # | Item |
|---|------|
| 15.1 | Multi-channel support (live chat, SMS, social, WhatsApp). Inbox2 is email-first. |
| 15.2 | Knowledge base / help center / customer self-service portal. |
| 15.3 | Built-in conversational AI drafting/summarization in the web UI. Note: agentic users (5.5) *are* in scope; what is deferred is in-composer AI assistance for human users. Spam filtering uses Rspamd, not an LLM (11.1). |
| 15.4 | Full ticketing taxonomy (custom ticket types, custom fields, child/sibling tickets). |
| 15.5 | SLA / response-time targets and escalation. Removed in v1.2; revisit if support-team demand emerges. |
| 15.6 | Reporting & analytics dashboards. Removed in v1.2; revisit post-launch. |
| 15.7 | Internal team chat. Removed in v1.2; private notes (9.1) cover in-conversation collaboration. |
| 15.8 | Voice / telephony. |
| 15.9 | Marketing or bulk-email sending — Inbox2 is operational mail, not campaigns. |

---

## 16. Indicative architecture

This section records the intended component shape and technology choices so the spec is internally consistent. Architecture is otherwise out of scope for this document; all technology choices below are settled.

### 16.1 Principles

- **16.1.1** Inbound and outbound mail handling are separate components from the application, connected by a queue, so mail throughput scales independently of the app.
- **16.1.2** Horizontal scale-out for every tier; **no Redis dependency** anywhere in the stack.
- **16.1.3** The HTTP API is **JSON-only by policy** — it renders no HTML pages; all UI lives in the clients (16.4). It runs as a *standard* Rails application (not API-only mode) so that framework features such as Action Cable WebSockets are available, but every response is rendered as JSON through a serializer layer (16.3.2).

### 16.2 Mail-handling components

| # | Component | Notes | Priority |
|---|-----------|-------|----------|
| 16.2.1 | **MX / inbound component** — receives inbound SMTP, accepts mail for verified domains, hands messages to the queue. Written in **Go**. Horizontally scalable behind the domain's MX records. | P0 |
| 16.2.2 | **SMTP / outbound component** — sends outbound mail (replies, forwards, auto-replies, notifications), handles DKIM signing and delivery/bounce feedback. Written in **Go**. Horizontally scalable. | P0 |
| 16.2.3 | **Queue** — links the MX and SMTP components to the rest of the system and lets inbound and outbound tiers scale out independently. Technology: **NATS with JetStream**, chosen for a single Go binary in one container, built-in Prometheus metrics for monitoring (with community web UIs such as nats-top / NATS surveyor available), persistence and at-least-once delivery via JetStream streams, native request-reply suiting the MX↔app↔SMTP flow, and no Redis dependency (consistent with 16.1.2). Anti-spam Layers 1–2 (11.1) run on or around this path. | P0 |

### 16.3 Application & storage

| # | Component | Notes | Priority |
|---|-----------|-------|----------|
| 16.3.1 | **Storage — database** — primary datastore for messages, conversations, metadata, members, rules, and views. PostgreSQL. Also provides full-text search (6.3) via its built-in `tsvector`/`tsquery` capability — no separate search service. | P0 |
| 16.3.2 | **HTTP API** — the application service: a **standard Rails application** (not API-only mode), JSON-only by policy. All responses are rendered through a serializer layer; **Alba** is the recommended serializer (modern, fast, dependency-free — it outperforms jbuilder in benchmarks), with jbuilder noted as a conservative fallback. Standard Rails is chosen specifically to make **Action Cable** WebSockets available for real-time features (16.3.4). No Redis dependency; designed to scale out horizontally (stateless app instances; state in Postgres / the queue). | P0 |
| 16.3.3 | **Storage — attachments/blobs** — an **S3-compatible object store**. The initial choice is **Garage**: a single-binary, single-container, easy-to-operate, actively-maintained S3-compatible store. (MinIO is deliberately excluded — its open-source community edition was archived in February 2026.) In production, scale out to **AWS S3**. The application addresses storage only through the S3 API, so the Garage→S3 swap is configuration, not code. | P0 |
| 16.3.4 | **Real-time channel** — Action Cable provides the WebSocket transport for collision detection (5.4), presence, and live conversation/list updates to the clients. To preserve the no-Redis principle, the Action Cable adapter must use a non-Redis backend (e.g. the PostgreSQL adapter). | P0 |
| 16.3.5 | **MCP server** (14.3) — exposes agent feeds and actions as MCP tools; deployed alongside or behind the API. | P1 |

### 16.4 Clients

| # | Component | Notes | Priority |
|---|-----------|-------|----------|
| 16.4.1 | **Web frontend** — React; the primary client (12.2.1). Consumes the JSON API and the Action Cable channel. | P0 |
| 16.4.2 | **Desktop frontend** — the web frontend packaged with Tauri for macOS/Windows/Linux (12.2.2). Unlike the web client, the desktop client adds a local datastore and an offline sync layer (16.7) so it remains usable without connectivity. | P1 |
| 16.4.3 | **CLI** — a Python terminal client built on Textual (12.2.4). | P2 |

### 16.5 Deployment

| # | Item | Notes | Priority |
|---|------|-------|----------|
| 16.5.1 | Local/dev and small-deployment topology is a **Docker Compose** stack. | P0 |
| 16.5.2 | **Rspamd** (11.1.2) runs as its own service in the Docker Compose stack — it is a third-party component and is kept as a separate, independently updatable container. | P0 |
| 16.5.3 | The Go MX and SMTP components, the NATS/JetStream queue, PostgreSQL, the Garage object store, the Rails API, and Rspamd are each independently deployable/scalable services. | P0 |

### 16.7 Offline sync (every native client)

Every native client (desktop, iOS, Android and the CLI) keeps a local mirror of the inbox2-hosted mail the member may see, plus the directory around it (organization, domains, mailboxes, members, tags, spaces, triage labels, views). Reads are served from the mirror, so the app works offline and hosted mail is available to local search, the MCP server and agents. The browser build has no SQLite and reads the API directly.

**Technology (settled 2026-09-20; see [MX-Sync.md](MX-Sync.md)).** The sync client is part of the shared Rust core, one implementation for all four clients. It speaks inbox2's own protocol against the Rails API: `sync/head`, `sync/pull` (an opaque forward cursor over trigger-stamped change sequences, safe against commit order through a transaction-horizon cursor), `sync/backfill` (history, newest first) and `sync/keys` (a periodic key-set reconcile that makes the mirror self-healing). PowerSync and ElectricSQL, recommended in v1.9, were not adopted. Yjs/CRDTs are not used: mail is structured rows, not a co-edited document.

| # | Item | Priority |
|---|------|----------|
| 16.7.1 | Each native client has a local SQLite mirror and works offline: reads are served locally, not from the core HTTP API on every request. Hosted mail sits in its own `mx_*` tables, apart from channel mail. | P1 |
| 16.7.2 | The sync layer replicates the member's accessible conversations, messages and directory down to the mirror. Local changes are not pushed as rows: each action is queued on the device and replayed against the real REST endpoint when the connection returns, so validation, activity events and broadcasts all run. | P1 |
| 16.7.3 | Technology: inbox2's own pull, backfill and reconcile protocol in the Rust core, over the Rails API. No third-party sync engine. | P1 |
| 16.7.4 | Sync is tenant-scoped: a client only ever replicates data for organizations and conversations the signed-in member may access (API standard E3). Losing visibility of a thread deletes it from the mirror. | P1 |
| 16.7.5 | Conflict handling is defined: the server is the authority; a version guard stops an older row replacing a newer one, and a settle guard stops a pull from undoing an action the device has queued but not yet replayed. Sent messages are immutable. | P1 |
| 16.7.6 | Depth is all mail, backfilled newest first in the background. A per-device window setting limits it on small devices. The mirror is a cache: a schema change drops and rebuilds it. | P2 |
| 16.7.7 | Sealed (end-to-end encrypted) mail is mirrored as ciphertext and opened on the device once the member unlocks. Opened text never goes to a cloud AI lane. | P1 |

> Sending while offline is out of scope. The React web client keeps using the core API directly.

---

## 17. Testing, seed data & performance

This section operationalises the binding requirement in 0.1.

### 17.1 Spec-item coverage

| # | Item | Priority |
|---|------|----------|
| 17.1.1 | Every numbered feature item must have at least one automated test exercising it. Target: **> 95% of spec items covered**. | P0 |
| 17.1.2 | Tests are tagged or otherwise mapped to spec item numbers, so a coverage report can list which items are covered and which are not. | P0 |
| 17.1.3 | A coverage report is produced in CI on every change and the spec-item coverage percentage is published; a drop below 95% fails the build. | P0 |
| 17.1.4 | Each component carries its own test suite in its native ecosystem: Go tests for the MX/SMTP components, the Rails test suite for the API, React component/integration tests for the web client, and tests for the Tauri and CLI clients. | P0 |
| 17.1.5 | End-to-end tests cover the critical mail paths — inbound capture into the pool, routing-rule execution, outbound send — across component boundaries. | P0 |
| 17.1.6 | Conventional code-coverage (line/branch) is also tracked per component as a secondary metric, but spec-item coverage (17.1.1) is the primary gate. | P1 |
| 17.1.7 | Agentic-user and anti-spam paths (5.5, 11.1, 11.4) have dedicated tests, including prompt-injection regression cases for the agentic-user surface. | P1 |

### 17.2 MX & SMTP component test suite

The Go MX (inbound) and SMTP (outbound) components need a full test suite that does two jobs: (a) QA the components themselves, and (b) let developers run them locally against a realistic test data set.

| # | Item | Priority |
|---|------|----------|
| 17.2.1 | The MX and SMTP components each have a full automated test suite (Go), covering protocol handling, parsing, the per-plan size limit (11.5), authentication checks (SPF/DKIM/DMARC, section 18), and error paths — positive and negative cases. | P0 |
| 17.2.2 | A curated **test corpus of email messages** — covering plain text, HTML, multipart/MIME, attachments, non-ASCII/internationalised content, malformed messages, oversized messages, and messages with varying authentication results — is maintained and used by the suite. | P0 |
| 17.2.3 | **Email-injection rake tasks** — rake (or equivalent) tasks that inject messages from the test corpus directly into the MX component, so a developer can exercise the full inbound pipeline (capture → routing → pool) locally without an external mail sender. | P0 |
| 17.2.4 | Outbound send testing — the SMTP component can be run locally against a sink/catcher so outbound mail is captured and inspected rather than actually delivered. | P0 |
| 17.2.5 | The MX/SMTP suite runs in CI and is part of the spec-item coverage gate (17.1). | P0 |
| 17.2.6 | Conformance tests against the supported email standards (section 18) — verifying the components correctly implement and enforce them. | P0 |

### 17.3 Seed data for local development

| # | Item | Priority |
|---|------|----------|
| 17.3.1 | The Rails application ships **seed data** (Rails seeds) that populates a realistic test account, organizations, members, conversations, tags, rules, and views — so the inbox, conversation view, and settings render with meaningful content for local development and demos. | P0 |
| 17.3.2 | Seed data and the MX email-injection tasks (17.2.3) compose: a developer can seed the app, inject mail, and see it flow into the seeded organizations' pools. | P0 |
| 17.3.3 | Seed and test data sets are versioned with the codebase and kept consistent with the current schema. | P1 |

### 17.4 Performance suites

| # | Item | Priority |
|---|------|----------|
| 17.4.1 | The MX component has a **performance/load test suite** that measures inbound throughput (messages/second), per-message processing latency, and behaviour under sustained and burst load. | P0 |
| 17.4.2 | The SMTP component has an equivalent performance suite for outbound throughput and latency. | P1 |
| 17.4.3 | Performance suites produce repeatable, comparable metrics so regressions are visible across changes; baseline figures are recorded. | P0 |
| 17.4.4 | Performance suites can be run locally and in CI; significant regressions are surfaced. | P1 |
| 17.4.5 | Load scenarios include the catch-all worst case — high volume of mail to many distinct addresses on one domain — and oversized-message rejection paths. | P1 |

---

## 18. Email standards

The MX and SMTP components are real internet mail servers and must implement the email standards that the major providers (Gmail, Yahoo, Microsoft/Outlook) require and support. This section enumerates the standards in scope. Research note (2026): Gmail and Yahoo enforced authentication requirements from February 2024 and Microsoft from May 2025; for bulk senders (5,000+ messages/day to a provider) SPF, DKIM, and DMARC are all mandatory with From-domain alignment, and unauthenticated mail is now effectively treated as a security threat.

### 18.1 Transport & message format (must implement)

| # | Item | Priority |
|---|------|----------|
| 18.1.1 | **SMTP — RFC 5321.** Core mail transport for the MX (inbound) and SMTP (outbound) components, including standard ESMTP extensions (`EHLO`, `SIZE`, `8BITMIME`, `PIPELINING`, `STARTTLS`). | P0 |
| 18.1.2 | **Internet Message Format — RFC 5322.** Parsing and generating message headers and bodies; threading identity (`Message-ID`, `In-Reply-To`, `References`) per spec 3.1.3. | P0 |
| 18.1.3 | **MIME — RFC 2045–2047, 2231.** Multipart messages, attachments, media types, non-ASCII headers and internationalised parameter values. | P0 |
| 18.1.4 | **STARTTLS — RFC 3207.** Opportunistic TLS on SMTP connections, inbound and outbound; encryption in transit (11.3.1). | P0 |
| 18.1.5 | **SMTP size declaration — `SIZE` extension (RFC 1870).** Used to advertise and enforce the per-plan mail size limit (11.5) at SMTP time. | P0 |

### 18.2 Authentication (must implement)

| # | Item | Priority |
|---|------|----------|
| 18.2.1 | **SPF — RFC 7208.** Validate inbound mail's sending IP against the sender domain's SPF record; publish correct SPF for outbound (2.3.x). | P0 |
| 18.2.2 | **DKIM — RFC 6376.** Verify DKIM signatures on inbound mail; DKIM-sign all outbound mail (2.3.7). | P0 |
| 18.2.3 | **DMARC — RFC 7489.** Evaluate DMARC (including SPF/DKIM alignment) on inbound; publish a DMARC policy for connected domains; the MX surfaces the DMARC result for use in filtering (11.1). | P0 |
| 18.2.4 | **ARC — RFC 8617.** Authenticated Received Chain — preserve upstream authentication results when mail is forwarded (relevant to the forward-to-external-address action, 7.3.8). | P1 |
| 18.2.5 | From-domain alignment is verified — the RFC 5322 From domain must align with the SPF or DKIM domain, matching the major providers' bulk-sender requirement. | P0 |

### 18.3 Transport security policy (should support)

| # | Item | Priority |
|---|------|----------|
| 18.3.1 | **MTA-STS — RFC 8461.** Publish an MTA-STS policy for connected domains so senders enforce TLS to Inbox2's MX; honour recipients' MTA-STS policies when sending. | P1 |
| 18.3.2 | **TLS-RPT — RFC 8460.** Publish a TLS reporting endpoint and consume TLS-RPT reports, to monitor transport-security health. | P1 |
| 18.3.3 | **MTA-DANE — RFC 7672.** Noted but **not** prioritised — it mandates DNSSEC, which the major providers have largely not adopted; MTA-STS is the chosen TLS-policy mechanism. | P2 |
| 18.3.4 | **REQUIRETLS — RFC 8689.** Optional per-message TLS-required handling. | P2 |

### 18.4 Deliverability & recipient-experience standards (outbound)

| # | Item | Priority |
|---|------|----------|
| 18.4.1 | Valid **PTR / reverse-DNS** on sending IPs, and correct forward-confirmed rDNS — a major-provider requirement. | P0 |
| 18.4.2 | **`List-Unsubscribe` and `List-Unsubscribe-Post` headers (RFC 8058)** — one-click unsubscribe. Inbox2 is operational mail, not bulk marketing (15.9), so this is lower priority, but supporting the headers keeps Inbox2 well-behaved if a customer sends list-like mail. | P1 |
| 18.4.3 | Standard bounce / delivery-status handling — DSN (RFC 3464) — so the SMTP component processes bounces and feeds them back (2.3.6 health, webhook delivery logs). | P1 |
| 18.4.4 | Keep outbound spam-complaint rates low and infrastructure clean, consistent with the major providers' bulk-sender expectations; relevant if a customer's volume grows. | P1 |

> Coverage note: section 17.2.6 requires conformance tests verifying the MX/SMTP components correctly implement section 18. The P0 items here are the non-negotiable baseline for being a deliverable, accepted mail server in 2026.

---

## 20. Outbound delivery channels & tracking

Inbox2's SMTP outbound component (16.2.2) delivers mail. By default it sends through its own infrastructure — the Go SMTP component behind the organization's sending IPs. This section adds two capabilities: (a) **delivery channels**, so an admin can configure external SMTP relays or Amazon SES as alternatives to self-hosted delivery, and (b) **message delivery tracking**, so every outbound message has a visible, queryable delivery status with per-attempt logging.

**Why channels matter.** Building IP reputation from scratch is slow and fragile — a new IP with no sending history will be throttled or junked by Gmail, Yahoo, and Microsoft. Organizations migrating to Inbox2, or those without the appetite to manage deliverability, can route outbound mail through an established relay (Mailgun, Postmark, SendGrid, their own Exchange connector) or through Amazon SES, which handles IP warm-up, feedback loops, and reputation. The built-in channel remains available for organizations that want full control.

### 20.1 Delivery channels

| # | Item | Priority |
|---|------|----------|
| 20.1.1 | Every organization has a **default delivery channel** — Inbox2's own SMTP outbound infrastructure (16.2.2). This is the built-in channel; no additional configuration is needed to send mail. | P0 |
| 20.1.2 | Admins can configure **external delivery channels**: an external SMTP relay (host, port, authentication credentials, TLS mode) or an **Amazon SES** integration (region, IAM access key / secret, verified identity ARN). Multiple channels can be configured per organization. | P1 |
| 20.1.3 | One channel is designated as the **organization default** — all outbound mail for the organization routes through it unless overridden (20.1.7). Changing the default is an admin action, logged in the audit log. | P1 |
| 20.1.4 | **Channel health check** — before activating an external channel, the admin can test connectivity and authentication; the result (success, error detail) is shown inline in the settings UI. | P1 |
| 20.1.5 | Channel status indicators: *Active*, *Error* (last delivery attempt failed), *Disabled* (manually turned off by admin). When an active external channel enters *Error* state, outbound mail **falls back to the built-in channel** and the admin is alerted — mail is never silently dropped. | P1 |
| 20.1.6 | Credentials for external channels (SMTP passwords, SES access keys) are **encrypted at rest** and are **write-only in the API** — they are accepted on create/update but never returned in read responses. | P1 |
| 20.1.7 | **Per-address or per-rule channel override** — route outbound mail from specific From addresses, or triggered by specific routing rules, through a designated channel instead of the organization default. | P2 |

### 20.2 Message delivery tracking

| # | Item | Priority |
|---|------|----------|
| 20.2.1 | Every outbound message carries a **delivery status**: *Queued* (accepted, waiting to send), *Sending* (in-flight), *Delivered* (remote server accepted with 2xx), *Failed* (permanent failure, 5xx or max retries exhausted), *Bounced* (DSN bounce received after initial acceptance), *Deferred* (transient failure, will retry). | P0 |
| 20.2.2 | Delivery status is visible **per-message** in the conversation view (a status indicator on each sent message) and in the **Sent** view (a column/badge). | P0 |
| 20.2.3 | **Automatic retry with backoff** on transient failures (SMTP 4xx responses). Permanent failures (5xx) are recorded immediately as *Failed*. A configurable maximum retry count (system-level default, admin-overridable per org) determines when a *Deferred* message becomes *Failed*. | P0 |
| 20.2.4 | Each delivery attempt is **logged**: timestamp, channel used, SMTP response code and enhanced status code, response message, and attempt number. The delivery log is viewable per-message in the conversation view. | P1 |
| 20.2.5 | On delivery failure (status transitions to *Failed* or *Bounced*), the sender and conversation assignees are **notified** via the in-app notification system (section 10). | P1 |
| 20.2.6 | **Bounce processing** — DSN bounce notifications (RFC 3464; see 18.4.3) received by the MX inbound component are parsed, matched to the original outbound message by Message-ID, and update its delivery status to *Bounced*. Hard bounces (permanent) vs. soft bounces (transient) are distinguished and recorded. | P1 |
| 20.2.7 | **Per-channel delivery statistics** — success rate, failure rate, bounce rate, average delivery latency — visible on the channel settings screen, computed over a configurable rolling window (default 30 days). | P1 |
| 20.2.8 | **Organization delivery log** — a searchable, filterable log of all outbound delivery attempts across the organization. Filterable by delivery status, channel, date range, and recipient domain. Accessible to admins. | P1 |

---

## 21. ESP: sending through an API

An application sends mail with one HTTP call and an organization sending key, and reads back what happened to each recipient. API sends have their own log and never enter the domain's inbox. Design and decisions: [docs/ESP.md](ESP.md), [docs/plans/esp.md](plans/esp.md).

### 21.1 Application side

| # | Item | Priority |
|---|------|----------|
| 21.1.1 | `POST /api/v1/esp/emails` accepts from, to, cc, bcc, subject, text, html, reply-to, custom headers, tag, metadata and attachments; stores the message and queues **one delivery per recipient**. No conversation is created. | P1 |
| 21.1.2 | Authentication is an **organization sending key** (`isk_…`), not a user. Personal `ink_` keys are refused. | P1 |
| 21.1.3 | The From domain must be a verified hosted domain of the organization or one of its verified **send-only domains**. Sealed domains are refused. | P1 |
| 21.1.4 | Caller headers are checked: reserved names and any CR/LF are rejected. | P1 |
| 21.1.5 | An `Idempotency-Key` header makes a repeated request return the first send. | P1 |
| 21.1.6 | Recipients on the organization's suppression list are not sent to. | P1 |
| 21.1.7 | Paid plans only, with a **monthly allowance** of sends per plan; 403 without one, 429 over it. | P1 |
| 21.1.8 | `GET /api/v1/esp/emails` and `/emails/:id` return the organization's sends with per-recipient status and events. | P1 |

### 21.2 Console side

| # | Item | Priority |
|---|------|----------|
| 21.2.1 | Admins create sending keys (token shown once) and revoke them. | P1 |
| 21.2.2 | All ESP console endpoints are admin-only. | P1 |
| 21.2.3 | Admins add **send-only domains**: domains that host no mail here, verified by the DKIM CNAME. | P1 |
| 21.2.4 | Admins read the send log and the month's use of the allowance. | P1 |

### 21.3 Delivery, bounces and events

| # | Item | Priority |
|---|------|----------|
| 21.3.1 | Each delivery has a status: queued, delivered, deferred, bounced, failed, complained. Every change is an event. | P1 |
| 21.3.2 | A permanent rejection about the address bounces the delivery and suppresses the address. | P1 |
| 21.3.3 | Transient failures retry with backoff, then fail. | P1 |
| 21.3.4 | Webhooks subscribed to `email.<status>` are told, signed like every other webhook. | P1 |
| 21.3.5 | Every delivery has its own bounce address; a bounce that arrives later settles the delivery it names. | P1 |
| 21.3.6 | Mail is DKIM-signed with `d=` the From domain. | P1 |
| 21.3.7 | A delivery result counts once and only for the attempt in flight; a repeated or late result changes nothing. | P1 |
| 21.3.8 | A delivery is published by one job at a time, and an accepted send that was never queued is queued again. | P1 |

---

## 22. Mail clients: IMAP and SMTP submission

A person reads and sends their own inbox2-hosted mail from any mail client. Off by default per organization. Design and decisions: [docs/Mail-Clients.md](Mail-Clients.md), [docs/plans/mail-clients.md](plans/mail-clients.md).

### 22.1 Switch and app passwords

| # | Item | Priority |
|---|------|----------|
| 22.1.1 | Mail-client access is **off by default**; an org admin switches it on. While off, sign-in is refused and no app password can be made. | P1 |
| 22.1.2 | A member makes, lists and revokes their own **app passwords** (shown once). The account password is never accepted by a mail client. | P1 |
| 22.1.3 | A member can read the settings to type into a mail client: hosts, ports, their addresses. | P1 |
| 22.1.4 | Mail-client access is a **paid-plan** feature: Free cannot switch it on, and a downgrade to Free closes it. | P1 |

### 22.2 What a mail client can do

| # | Item | Priority |
|---|------|----------|
| 22.2.1 | Sign-in is one of the person's own addresses plus an app password. | P1 |
| 22.2.2 | Sealed domains are refused. | P1 |
| 22.2.3 | Only the person's own mail is served, in five folders (INBOX, Archive, Sent, Trash, Junk), with stable UIDs. The shared domain inbox is never served. | P1 |
| 22.2.4 | Messages are served with their original headers; the body is rebuilt the same way every time and the listed size matches the bytes. | P1 |
| 22.2.5 | Read, flag, move, delete and search change the thread in inbox2. A mail client cannot remove mail for good. | P1 |
| 22.2.6 | Sending goes through the normal outbound pipeline as the person's own sent mail; the person can only send as their own addresses. | P1 |

---

## 19. Release summary

**19.1 — v1 (P0): the credible launch.** Username/password signup with a separate external billing email, account-and-organizations model, domain connect with DNS verification including one-click Cloudflare, the unified pool with system and user-defined views, conversation list and reading view, reply/forward composer with multi-address sending, member invites with roles and unlimited seats, assignment, member-access-by-tagging, collision detection over Action Cable, statuses, tags, search, the routing-rule builder with the webhook action, private notes, notifications, layered anti-spam (protocol + Rspamd), core security, dark/light themes, the React web client, the Free and paid plans with a trial and billing grace handling, the Go MX/SMTP components with their test/seed/performance suites and email-standards conformance, the NATS/JetStream queue, PostgreSQL, the Garage S3-compatible attachment store, the standard-Rails JSON API, the Docker Compose deployment with Rspamd, the testing/coverage gate, and **per-message delivery status tracking** with automatic retry on transient failures.

**19.2 — v1.x (P1): the fast follow.** Passkeys/TOTP, alias domains, organization switcher, shared/team views, OR-logic filters, snooze, canned responses, signatures, send-later, rule run-logs and dry-run, round-robin assignment, limited-member role, **agentic users with the API/MCP interface and route-to-agent action**, prompt-injection safeguards, mail import, browser push, tiered plans, the Tauri desktop client with offline sync, ARC and MTA-STS/TLS-RPT support, the MCP server, and **external delivery channels** (SMTP relay / Amazon SES) with per-channel health checks, delivery statistics, bounce processing, and a searchable delivery log.

**19.3 — Later (P2): depth.** Collaborative drafting, custom statuses/roles, contact CRM fields, the Textual CLI, native mobile apps, additional DNS-provider integrations, native integrations, agent rate/spend limits and run logs, MTA-DANE/REQUIRETLS, agency/reseller billing, and per-address/per-rule delivery channel overrides.
