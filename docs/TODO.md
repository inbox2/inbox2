# Inbox2 — Implementation TODO

Ordered by implementation priority (dependency-driven). Each item has checkboxes:
- **Tests** — automated tests covering the item (positive + negative, spec-item mapped)
- **XC** — cross-cutting concerns applied (E1–E5 for API, F1–F4 for frontend)
- **Simplify** — code reviewed for reuse, quality, efficiency

---

## Wave 1 — P0 (Must Ship)

### 1. Project Scaffolding & Infrastructure

- [x] 1.1 Initialize Rails API project (`api/`) — standard Rails, JSON-only, Alba serializer, PostgreSQL, Action Cable with Postgres adapter (spec 16.3.2, 16.1.2, 16.1.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 1.2 Initialize React web app (`ui/web/`) — Vite + React, CSS Modules, design tokens, dark/light themes (spec 16.4.1, F1, G1, G2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 1.3 Docker Compose stack — Rails API, PostgreSQL, NATS/JetStream, Garage S3, Rspamd (spec 16.5.1, 16.5.2, 16.5.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 1.4 Design token layer — colors, spacing, typography, radii, shadows, elevation for dark + light themes (spec F1.4, G2.2, G2.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 1.5 Component library + Storybook setup (spec F2.1–F2.6)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 1.6 Icon component wrapping SF Symbols (spec F3.1–F3.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 1.7 Base layout shell — sidebar + list + conversation pane, two/three column (spec 12.1.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 1.8 Keyboard operability framework — focus management, visible focus states, tab order (spec F4.1–F4.7, 12.1.10)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 1.9 Error response template — consistent error shape across all endpoints (spec E2.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 1.10 Public ID generation — prefixed UUIDs (`conv_`, `org_`, `msg_`, etc.) (spec E5.1–E5.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 1.11 Tenant isolation base — query scoping concern for all org-scoped models (spec E3.1–E3.4)
  - [x] Tests  - [x] XC  - [x] Simplify

### 2. Authentication (A1, S1)

- [x] 2.1 `POST /api/v1/auth/signup` — username + password, create account owner (spec 2.1.1, A1.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 2.2 `POST /api/v1/auth/login` — session token (spec 2.1.3, A1.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 2.3 `POST /api/v1/auth/logout` (spec 2.1.3, A1.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 2.4 `POST /api/v1/auth/password/reset-request` + `POST .../reset` (spec 2.1.3, A1.4, A1.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 2.5 `GET /api/v1/auth/sessions` — list active sessions (spec 2.1.4, A1.6)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 2.6 `DELETE /api/v1/auth/sessions` — sign out all (spec 2.1.4, A1.7)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 2.7 S1.1 Sign up screen (spec S1.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 2.8 S1.2 Log in screen (spec S1.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 2.9 S1.3–S1.4 Forgot / reset password screens (spec S1.3, S1.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 2.10 S1.5 Accept invitation screen (spec S1.5)
  - [x] Tests  - [x] XC  - [x] Simplify

### 3. Account (A2, S8)

- [x] 3.1 Account model + `GET /api/v1/account` (spec 2.2.2, A2.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 3.2 `PATCH /api/v1/account` — update settings (spec 2.2.2, A2.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 3.3 `PUT /api/v1/account/billing-email` — external billing email, warn if Inbox2-hosted (spec 2.1.8, A2.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 3.4 S8.1 Account settings screen (spec S8.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 3.5 S8.2 Billing email screen (spec S8.2)
  - [x] Tests  - [x] XC  - [x] Simplify

### 4. Organizations & Domains (A3, S2, S9.5)

- [x] 4.1 Organization model — per-domain, segregated data (spec 2.2.1, 2.2.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 4.2 `POST /api/v1/orgs` — add domain, create org (spec 2.3.1, A3.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 4.3 `GET /api/v1/orgs/{org_id}` + `PATCH` — read/update org settings (spec A3.2, A3.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 4.4 `GET /api/v1/orgs/{org_id}/dns` — DNS records with pass/fail status (spec 2.3.2, 2.3.3, A3.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 4.5 `POST /api/v1/orgs/{org_id}/dns/verify` — re-check DNS (spec A3.6)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 4.6 `POST /api/v1/orgs/{org_id}/dns/cloudflare` — one-click Cloudflare DNS (spec 2.3.2, A3.7)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 4.7 `POST /api/v1/orgs/{org_id}/test-email` — onboarding diagnostic (spec 2.4.2, A3.11)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 4.8 `GET /api/v1/orgs/{org_id}/onboarding` — checklist state (spec 2.4.1, A3.12)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 4.9 S2.1 Onboarding checklist screen (spec S2.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 4.10 S2.2 Add domain wizard (spec S2.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 4.11 S2.3 DNS setup screen — per-record status, copy-paste, Cloudflare one-click (spec S2.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 4.12 S2.4 DNS verification waiting screen (spec S2.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 4.13 S2.5 Invite team screen (spec S2.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 4.14 S2.6 First rule prompt (spec S2.6)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 4.15 S2.7 Test email confirmation screen (spec S2.7)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 4.16 S9.5 Domain & DNS settings screen (spec S9.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 4.17 S9.8 Organization preferences screen (spec S9.8)
  - [x] Tests  - [x] XC  - [x] Simplify

### 5. Members & Roles (A4, S9.4)

- [x] 5.1 Member model — human/agent type, roles (Owner/Admin/Member), per-org (spec 5.1.3, 5.1.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 5.2 `GET /api/v1/orgs/{org_id}/members` (spec A4.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 5.3 `POST /api/v1/members/invite-mx` — invite by email (spec 5.1.1, A4.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 5.4 `POST /api/v1/members/accept-invite` — set username + password (spec A4.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 5.5 `PATCH /api/v1/orgs/{org_id}/members/{id}` — role, enable/disable (spec A4.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 5.6 `DELETE /api/v1/orgs/{org_id}/members/{id}` — remove, reassign conversations (spec 5.1.4, A4.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 5.7 Unlimited members enforcement — adding never affects price (spec 5.1.2, 13.1.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 5.8 Free plan: block 2nd collaborator (spec 13.1.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 5.9 S9.4 Team/members settings screen (spec S9.4)
  - [x] Tests  - [x] XC  - [x] Simplify

### 6. Tags & Statuses (A9, S9.3)

- [x] 6.1 Tag model — org-level, name + color (spec 6.2.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 6.2 `GET/POST/PATCH/DELETE /api/v1/orgs/{org_id}/tags` (spec A9.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 6.3 `PUT /api/v1/orgs/{org_id}/conversations/{id}/tags` — apply/remove tags [WS] (spec A9.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 6.4 Core statuses — Open, Snoozed/Pending, Archived (spec 6.1.1, 6.1.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 6.5 S9.3 Tags settings screen (spec S9.3)
  - [x] Tests  - [x] XC  - [x] Simplify

### 7. Views (A10, S4.1, S4.5)

- [x] 7.1 View model — system views + personal saved views, filter criteria (spec 3.2.x, 3.3.x)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 7.2 System views: All Mail, Assigned to me, Mentioned, Unassigned, Sent, Drafts (spec 3.2.1–3.2.6)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 7.3 `GET /api/v1/orgs/{org_id}/views` — list available views (spec A10.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 7.4 `POST /api/v1/orgs/{org_id}/views` — create personal saved view (spec 3.3.1, A10.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 7.5 `PATCH/DELETE /api/v1/orgs/{org_id}/views/{id}` — update/delete/reorder (spec A10.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 7.6 `PUT /api/v1/orgs/{org_id}/settings/view-policy` — admin controls view creation (spec 3.3.1, A10.8)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 7.7 Filter criteria: to/cc, sender, subject, body, tag, status, assignee, has-attachment, date range, matched rule (spec 3.3.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 7.8 AND logic for combining criteria (spec 3.3.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 7.9 S4.1 Sidebar — system + personal views, reorderable (spec S4.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 7.10 S4.5 Saved-view editor — filter criteria builder (spec S4.5)
  - [x] Tests  - [x] XC  - [x] Simplify

### 8. Conversations & the Pool (A6, S4, S5)

- [x] 8.1 Conversation model — threads, metadata (status, assignees, tags, access, recipients, rules) (spec 3.1.2–3.1.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 8.2 Message model — RFC 5322 threading (Message-ID, In-Reply-To, References) (spec 3.1.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 8.3 PostgreSQL full-text search — tsvector/tsquery on subject, body, sender, recipient, attachment filenames (spec 6.3.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 8.4 `GET /api/v1/orgs/{org_id}/conversations` — list with filter/sort/view/pagination [WS] (spec A6.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 8.5 `GET /api/v1/orgs/{org_id}/conversations/{id}` — thread, messages, notes, metadata (spec A6.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 8.6 `PATCH /api/v1/orgs/{org_id}/conversations/{id}` — set status, read/unread [WS] (spec A6.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 8.7 `POST /api/v1/orgs/{org_id}/conversations/bulk` — bulk actions (spec 3.4.3, A6.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 8.8 `POST .../archive` / `trash` / `spam` [WS] (spec A6.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 8.9 `GET .../raw/{message_id}` — original raw source/headers (spec 4.1.5, A6.10)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 8.10 `GET /api/v1/orgs/{org_id}/search` — full-text search with operators, scoped (spec 6.3.1–6.3.3, A10.6)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 8.11 S4.2 Conversation list — sender, subject, snippet, time, tags, assignees, status, unread (spec S4.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 8.12 S4.3 Bulk-action bar (spec S4.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 8.13 S4.4 Empty/zero state (spec S4.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 8.14 S4.6 Search results screen (spec S4.6)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 8.15 S5.1 Conversation thread view — expandable messages, trimmed quotes, safe HTML, attachments (spec S5.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 8.16 S5.2 Conversation toolbar (spec S5.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 8.17 S5.3 Contact sidebar — sender details + history (spec S5.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 8.18 S5.4 Properties sidebar — recipients, rules, status, tags, assignees, access (spec S5.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 8.19 Safe HTML email rendering with image proxying + remote-content blocking (spec 4.1.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 8.20 Plain-text fallback rendering (spec 4.1.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 8.21 Attachment list per message — filename, type icon, size, download, inline preview (spec 4.1.4)
  - [x] Tests  - [x] XC  - [x] Simplify

### 9. Messages, Attachments & Sending (A7, S6)

- [x] 9.1 `POST /api/v1/orgs/{org_id}/messages` — reply/reply-all/forward/new, choose From address, enforce size limit (spec A7.1, 11.5.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 9.2 `GET /api/v1/orgs/{org_id}/attachments/{id}` — download from S3 (spec A7.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 9.3 `POST /api/v1/orgs/{org_id}/attachments` — upload, enforce size limit (spec A7.3, 11.5.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 9.4 `GET/POST/PATCH/DELETE /api/v1/orgs/{org_id}/drafts` — drafts with size tracking (spec A7.4, 11.5.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 9.5 S6.1 Composer — rich text, From picker, CC/BCC, drag-drop, inline images, auto-save, size indicator (spec S6.1)
  - [x] Tests  - [x] XC  - [x] Simplify

### 10. Assignment & Access (A8)

- [x] 10.1 `PUT /api/v1/orgs/{org_id}/conversations/{id}/assignees` — set assignees [WS] (spec A8.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 10.2 `DELETE .../assignees/{member_id}` — unassign (spec A8.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 10.3 `PUT .../access` — grant access by tagging members [WS] (spec A8.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 10.4 `DELETE .../access/{member_id}` — revoke access (spec A8.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 10.5 Assignment visible in list + conversation view; assignees notified (spec 5.2.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 10.6 Assignment history in activity log (spec 5.2.3)
  - [x] Tests  - [x] XC  - [x] Simplify

### 11. Collision Detection & Presence (A12.3)

- [x] 11.1 `GET .../presence` + Action Cable channel — who's viewing/replying [WS] (spec 5.4.1, 5.4.2, A12.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 11.2 S5.8 Presence indicator in conversation view (spec S5.8)
  - [x] Tests  - [x] XC  - [x] Simplify

### 12. Notes & Collaboration (A12, S5.7)

- [x] 12.1 Note model — internal, never visible to external sender (spec 9.1.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 12.2 `POST .../conversations/{id}/notes` — add note, @mentions notify + grant access [WS] (spec A12.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 12.3 Notes visually distinct in thread, chronological, support formatting + attachments (spec 9.1.2, 9.1.4, 9.1.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 12.4 S5.7 Private notes inline in conversation thread (spec S5.7)
  - [x] Tests  - [x] XC  - [x] Simplify

### 13. Routing Rules & Webhooks (A11, S9.1, S9.2)

- [x] 13.1 Rule model — name, on/off, order, conditions, actions (spec 7.1.1–7.1.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 13.2 `GET/POST/PATCH/DELETE /api/v1/orgs/{org_id}/rules` (spec A11.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 13.3 `PUT .../rules/order` — reorder priority (spec A11.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 13.4 `PATCH .../rules/{id}/toggle` — enable/disable (spec A11.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 13.5 Rule conditions: recipient, sender, subject, body, has-attachment (spec 7.2.1–7.2.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 13.6 Rule actions: assign, grant access, add tags, set status (spec 7.3.1–7.3.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 13.7 Webhook action — POST to external HTTP endpoint (spec 7.3.5, 7.4.1–7.4.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 13.8 `GET/POST/PATCH/DELETE .../webhooks` (spec A11.6)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 13.9 Rule execution on inbound messages (spec 7.1.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 13.10 S9.1 Routing rules settings — visual builder, conditions + actions (spec S9.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 13.11 S9.2 Webhooks settings — endpoint management (spec S9.2)
  - [x] Tests  - [x] XC  - [x] Simplify

### 14. Notifications (A14, S3.2, S10.2)

- [x] 14.1 Notification model — assignments, @mentions, access grants, replies (spec 10.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 14.2 `GET /api/v1/notifications` [WS] (spec A14.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 14.3 `POST /api/v1/notifications/read` (spec A14.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 14.4 `GET/PUT /api/v1/notifications/preferences` (spec A14.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 14.5 Email notifications for events with per-event toggles (spec 10.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 14.6 S3.2 Notification center panel (spec S3.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 14.7 S10.2 Notification preferences screen (spec S10.2)
  - [x] Tests  - [x] XC  - [x] Simplify

### 15. Spam & Security (A15, S9.6, S9.9)

- [x] 15.1 `GET/POST/DELETE .../blocklist` + `allowlist` (spec A15.1, 11.1.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 15.2 `POST .../spam-feedback` — mark spam/not-spam (spec A15.2, 11.1.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 15.3 `GET /api/v1/orgs/{org_id}/audit-log` (spec A15.5, 11.3.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 15.4 Encryption at rest for stored mail and attachments (spec 11.3.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 15.5 S9.6 Spam & filtering settings (spec S9.6)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 15.6 S9.9 Audit log screen (spec S9.9)
  - [x] Tests  - [x] XC  - [x] Simplify

### 16. Billing & Plans (A16, S8.3)

- [x] 16.1 Plan model — Free (1 domain, 1 collab, 20MB, no spam) vs Paid ($19/mo, unlimited, 100MB, spam) (spec 13.1.1–13.1.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 16.2 `GET /api/v1/plans` (spec A16.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 16.3 `GET /api/v1/account/billing` (spec A16.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 16.4 `POST /api/v1/account/billing/subscribe` + `PATCH` (spec A16.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 16.5 `GET /api/v1/account/billing/invoices` (spec A16.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 16.6 `PUT /api/v1/account/billing/payment-method` (spec A16.6)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 16.7 `POST /api/v1/account/billing/trial` — start free trial (spec 13.2.2, A16.8)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 16.8 Plan-limit enforcement — cross-cutting: block 2nd domain/collab on Free, upgrade prompt (spec 13.1.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 16.9 Billing grace period — no mail cutoff on payment failure (spec 13.2.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 16.10 S8.3 Billing & plan screen — comparison, upgrade/downgrade, payment, invoices (spec S8.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 16.11 S12.3 Billing past-due banner (spec S12.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 16.12 S12.6 Upgrade required screen (spec S12.6)
  - [x] Tests  - [x] XC  - [x] Simplify

### 17. Account Shell & Member Preferences (S3, S10)

- [x] 17.1 S3.3 Account menu — avatar dropdown, profile, settings, logout (spec S3.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 17.2 S3.4 Global command palette — keyboard entry to any screen/action (spec S3.4, 12.1.6, F4.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 17.3 S8.4 Security settings — password, sessions (spec S8.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 17.4 S10.1 Profile screen (spec S10.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 17.5 S10.3 Appearance screen — dark/light theme, density, default view (spec S10.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 17.6 Keyboard shortcuts for high-frequency actions + shortcut reference (spec 12.1.5)
  - [x] Tests  - [x] XC  - [x] Simplify

### 18. System & Error Screens (S12)

- [x] 18.1 S12.1 Not found (404) (spec S12.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 18.2 S12.2 No access screen (spec S12.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 18.3 S12.4 Connection-lost indicator (spec S12.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 18.4 S12.5 Generic error screen (spec S12.5)
  - [x] Tests  - [x] XC  - [x] Simplify

### 19. Mail Size Limits (cross-cutting)

- [x] 19.1 Configurable system constants: 20MB Free / 100MB Paid (spec 11.5.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 19.2 Composer shows active limit + current message size (spec 11.5.3)
  - [x] Tests  - [x] XC  - [x] Simplify

### 20. Responsive Layout

- [x] 20.1 Responsive layout usable on tablet and small screens (spec 12.1.4)
  - [x] Tests  - [x] XC  - [x] Simplify

### 21. Message Delivery Tracking (A18 P0, S5)

- [x] 21a.1 DeliveryStatus model — per outbound message: Queued, Sending, Delivered, Failed, Bounced, Deferred (spec 20.2.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 21a.2 DeliveryAttempt model — per-attempt log: timestamp, channel, SMTP response code, message, attempt number (spec 20.2.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 21a.3 Default delivery channel — built-in SMTP outbound, always present per org (spec 20.1.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 21a.4 `GET /api/v1/orgs/{org_id}/delivery-channels` — list channels (built-in at minimum) (spec A18.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 21a.5 `GET /api/v1/orgs/{org_id}/messages/{message_id}/delivery` — delivery status + attempts (spec A18.9)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 21a.6 Automatic retry with exponential backoff on transient 4xx failures, immediate fail on 5xx (spec 20.2.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 21a.7 Delivery status indicator on sent messages in conversation view (spec 20.2.2, S5.1)
  - [x] Tests  - [x] XC  - [x] Simplify

### 22. Seed Data & Testing Infrastructure

- [x] 22.1 Rails seeds — realistic account, orgs, members, conversations, tags, rules, views (spec 17.3.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 22.2 Spec-item coverage tracking — tests tagged to spec numbers (spec 17.1.2, 17.1.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 22.3 End-to-end tests for critical mail paths (spec 17.1.5)
  - [x] Tests  - [x] XC  - [x] Simplify

---

## Wave 2 — P1 (Fast Follow)

### 22. Second Factors (A1.8–A1.10, S1.6–S1.7)
- [x] 22.1 TOTP enrolling/verification (spec 2.1.5, A1.8)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 22.2 Passkey/WebAuthn registration + auth (spec 2.1.5, A1.9)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 22.3 Social/SSO login — Google, Microsoft (spec 2.1.6, A1.10)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 22.4 S1.6 Two-factor challenge screen
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 22.5 S1.7 SSO callback screen
  - [x] Tests  - [x] XC  - [x] Simplify

### 23. Organization Management (P1)
- [x] 23.1 Alias domains (spec 2.2.5, A3.8)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 23.2 Organization switcher (spec 2.2.7, A2.4, S3.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 23.3 Transfer ownership — account + org (spec 2.2.6, A2.5, A3.10)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 23.4 Delete organization with full data removal (spec 11.3.4, A3.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 23.5 Domain health monitoring with alerts (spec 2.3.6, A3.9)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 23.6 S3.5 Organizations overview screen
  - [x] Tests  - [x] XC  - [x] Simplify

### 24. Advanced Views & Search (P1)
- [x] 24.1 OR logic + grouped conditions (spec 3.3.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 24.2 Shared/team views (spec 3.3.6, A10.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 24.3 Unread counts/badges per view [WS] (spec 3.3.7, A10.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 24.4 Save search as view (spec 6.3.4, A10.7)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 24.5 Search operators (spec 6.3.3)
  - [x] Tests  - [x] XC  - [x] Simplify

### 25. Advanced Conversation Features (P1)
- [x] 25.1 Snooze/unsnooze (spec 4.2.7, A6.6)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 25.2 Merge conversations (spec 4.2.8, A6.7)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 25.3 Split message into new conversation (spec 4.2.8, A6.8)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 25.4 Activity log timeline (spec 4.3.4, A6.9)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 25.5 Export conversation to PDF (spec 4.1.6, A6.11)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 25.6 Snoozed/Archived/Spam/Trash views (spec 3.2.7–3.2.9)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 25.7 List density options (spec 3.4.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 25.8 Pagination/infinite scroll (spec 3.4.6)
  - [x] Tests  - [x] XC  - [x] Simplify

### 26. Advanced Composer (P1)
- [x] 26.1 Signatures — personal + org, HTML, per-From (spec 8.1.7, A13.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 26.2 Send later / scheduled send (spec 8.1.8, A7.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 26.3 Undo send (spec 8.1.9, A7.6)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 26.4 Shared draft (spec 8.1.10)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 26.5 Canned responses / templates (spec 8.2.1–8.2.3, A13.1)
  - [x] Tests  - [x] XC  - [x] Simplify

### 27. Advanced Rules & Automation (P1)
- [x] 27.1 Rules on conversation events (spec 7.1.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 27.2 Per-rule run log (spec 7.1.5, A11.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 27.3 Dry run (spec 7.1.6, A11.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 27.4 Advanced conditions: domain, header, regex, AND/OR grouping, spam score (spec 7.2.6–7.2.10)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 27.5 Round-robin assignment (spec 7.3.6, 5.2.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 27.6 Auto-reply, forward, mark spam/archive/delete, snooze actions (spec 7.3.7–7.3.10)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 27.7 Route-to-agent action (spec 7.3.13)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 27.8 Webhook: delivery log, retry, signing secret (spec 7.4.3–7.4.5, A11.7)
  - [x] Tests  - [x] XC  - [x] Simplify

### 28. Members (P1)
- [x] 28.1 Limited Member role (spec 5.1.6)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 28.2 Per-org membership (spec 5.1.7)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 28.3 Out-of-office flag (spec 5.2.5, A4.6)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 28.4 Typing indicators (spec 5.4.3)
  - [x] Tests  - [x] XC  - [x] Simplify

### 29. Agentic Users & MCP (A5, A17, S7, S11)
- [x] 29.1 Agent CRUD (spec 5.5.1, A5.1–A5.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 29.2 Agent API credentials (spec 5.5.2, A5.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 29.3 Agent routed feed (spec 5.5.3, A5.6)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 29.4 Agent permission scope + approval mode (spec 5.5.4, A5.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 29.5 Agent supervisor + escalation (spec 5.5.6)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 29.6 Approval queue (spec 5.5.7, A5.9)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 29.7 Prompt-injection safeguards (spec 11.4.1–11.4.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 29.8 MCP server (spec 14.3, A17.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 29.9 API keys management (spec 14.5, A17.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 29.10 Event webhooks (spec 14.4, A17.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 29.11 S7.1 Approval queue screen
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 29.12 S11.1–S11.2 Agents list + config screens
  - [x] Tests  - [x] XC  - [x] Simplify

### 30. Advanced Notifications (P1)
- [x] 30.1 Browser push notifications (spec 10.4, A14.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 30.2 Digest mode (spec 10.5)
  - [x] Tests  - [x] XC  - [x] Simplify

### 31. Spam & Security (P1)
- [x] 31.1 Allow list / trusted senders (spec 11.1.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 31.2 Adjustable spam aggressiveness (spec 11.1.6, A15.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 31.3 Structured-aliases-only mode (spec 11.1.7)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 31.4 Mail import — IMAP (spec 11.2.1, A15.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 31.5 Data export (spec 11.3.3, A15.6) — real zip export (mbox per domain + .ics per calendar) since 2026-09-25; was a counts-only stub before
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 31.6 Account/org deletion with full data removal (spec 11.3.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 31.7 GDPR contact data export/deletion (spec 11.3.5, A15.7)
  - [x] Tests  - [x] XC  - [x] Simplify

### 32. Billing (P1)
- [x] 32.1 Downgrade handling (spec 13.2.5, A16.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 32.2 Annual billing option (spec 13.1.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 32.3 Usage indicators (spec 13.2.3, A16.7)
  - [x] Tests  - [x] XC  - [x] Simplify

### 33. Email Standards (P1)
- [x] 33.1 ARC — RFC 8617 (spec 18.2.4) — `ArcHeaderService` now produces real RSA-SHA256 signatures (relaxed canonicalization, central DKIM key). _Remaining: not yet wired into a forwarding/relay path._
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 33.2 MTA-STS — RFC 8461 (spec 18.3.1) — policy **served** at `mta-sts.<domain>/.well-known/mta-sts.txt` (`WellKnownController#mta_sts`) AND **enforced outbound** (mta/internal/mtasts — see 46.9).
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 33.3 TLS-RPT — RFC 8460 (spec 18.3.2) — DNS record generation + **report ingestion** (InboundReportRouter → MailAuthReport, see 46.10). Sending our own reports: not planned.
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 33.4 List-Unsubscribe headers (spec 18.4.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 33.5 DSN bounce handling (spec 18.4.3)
  - [x] Tests  - [x] XC  - [x] Simplify

### 34. Advanced Screens (P1)
- [x] 34.1 S5.5 Activity sidebar
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 34.2 S5.6 Attachments sidebar
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 34.3 S6.2 Template picker
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 34.4 S6.3 Schedule-send dialog
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 34.5 S6.4 Shared draft/review state
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 34.6 S8.5 API keys screen
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 34.7 S9.7 Mail import screen
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 34.8 S9.10 Templates & signatures screen
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 34.9 S9.11 Data & compliance screen
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 34.10 S10.4 Personal signature screen
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 34.11 S13.1 Product tour overlay
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 34.12 S13.2 Diagnostics screen
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 34.13 Link-safety warnings for suspicious URLs (spec 4.1.7)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 34.14 Note edit/delete with history (spec 9.1.6, A12.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 34.15 Accessibility — contrast, screen-reader labelling, reduced-motion (spec 12.3.1)
  - [x] Tests  - [x] XC  - [x] Simplify

### 35. Desktop Client — Tauri + Offline Sync (P1)

Tauri v2 wrapper loads React web app in native window. Custom REST sync via `/sync/pull` + `/sync/push` endpoints. SQLite via tauri-plugin-sql with offline-first schema.

> Superseded 2026-09-20: the sync below was replaced by the MX mirror in the Rust core (`sync/head|pull|backfill|keys`, no `sync/push`; docs/MX-Sync.md, Feature-Spec 16.7 as of v1.12). The ticked items record what was built first.

- [x] 35.1 Tauri wrapper for web app (spec 16.4.2, 12.2.2) — Tauri v2, auto-starts Vite in dev, builds from ui/web/dist in production
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 35.2 Local SQLite datastore (spec 16.7.1) — tauri-plugin-sql with migration, conversations/messages/tags/memberships/pending_changes tables
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 35.3 Custom REST offline sync layer (spec 16.7.2–16.7.3) — SyncEngine with push/pull polling, Rails SyncController endpoints, tauri-db.js SQLite bridge
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 35.4 Tenant-scoped sync (spec 16.7.4) — all queries scoped by organization_id, pull endpoint tenant-isolated
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 35.5 Conflict handling — last-write-wins for conversations, server-wins for tags/memberships, immutable messages (spec 16.7.5)
  - [x] Tests  - [x] XC  - [x] Simplify

### 36. External Delivery Channels (A18 P1, S9.12)
- [x] 36a.1 DeliveryChannel model — type (built_in, smtp_relay, ses), config, encrypted credentials, status (spec 20.1.2, 20.1.6)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 36a.2 `POST /api/v1/orgs/{org_id}/delivery-channels` — add external channel, write-only credentials (spec A18.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 36a.3 `GET/PATCH/DELETE .../delivery-channels/{id}` — read (redacted), update, remove (spec A18.3–A18.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 36a.4 `POST .../delivery-channels/{id}/test` — health check, test connectivity + auth (spec 20.1.4, A18.6)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 36a.5 `PUT .../delivery-channels/default` — set org default channel (spec 20.1.3, A18.7)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 36a.6 Channel status (Active/Error/Disabled) + fallback to built-in on error (spec 20.1.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 36a.7 `GET .../delivery-channels/{id}/stats` — per-channel delivery statistics (spec 20.2.7, A18.8)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 36a.8 `GET .../delivery-log` — organization-wide searchable delivery log (spec 20.2.8, A18.10)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 36a.9 Delivery failure notifications — notify sender + assignees on Failed/Bounced (spec 20.2.5) — done as 46.8 (`DeliveryFailureNotifier` + `delivery_failure` Notification kind).
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 36a.10 Bounce processing — parse DSN bounces, match to original message, update status (spec 20.2.6)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 36a.11 S9.12 Delivery channels settings screen — channel list, add/edit, health check, stats (spec S9.12)
  - [x] Tests  - [x] XC  - [x] Simplify

---

## Wave 3 — P2 (Later)

### 36. Advanced Features (P2)
- [x] 36.1 SAML SSO (spec 2.1.7, A1.11)
- [x] 36.2 Custom roles + granular permissions (spec 5.1.8, A4.7)
- [x] 36.3 Member groups/teams (spec 5.1.9, A4.8)
- [x] 36.4 Collaborative drafting (spec 5.4.4, 8.1.11)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 36.5 Custom statuses (spec 6.1.4, A9.4)
- [x] 36.6 Search inside attachments (spec 6.3.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 36.7 Conditional branching rules (spec 7.3.12)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 36.8 Stop processing flag (spec 7.3.11)
- [x] 36.9 Custom webhook payloads (spec 7.4.6–7.4.7)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 36.10 Contact CRM fields (spec 4.3.5)
- [x] 36.11 Conversation-to-task (spec 4.2.10, A6.12)
- [x] 36.12 Note reactions/threaded replies (spec 9.1.7)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 36.13 Smart suggested views (spec 3.3.8)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 36.14 Additional themes (spec 12.1.9)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 36.15 Tag groups (spec 6.2.3, A9.3)
- [x] 36.16 Agent run logs + rate/spend limits (spec 5.5.8–5.5.9, A5.7–A5.8)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 36.17 Prompt-injection detection check (spec 11.4.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 36.18 Configurable data retention (spec 11.3.6)
- [x] 36.19 Per-conversation access restrictions (spec 11.3.7)
- [x] 36.20 Agency/reseller billing (spec 13.2.7)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 36.21 MTA-DANE (spec 18.3.3)
- [x] 36.22 REQUIRETLS (spec 18.3.4)
- [x] 36.23 Python/Textual CLI client (spec 12.2.4, 16.4.3) — full Textual TUI over the shared Rust engine bus, headless Pilot tests. See docs/CLI.md.
- [x] 36.24 Native iOS/Android apps (spec 12.2.5) — SwiftUI + Jetpack Compose clients over the shared Rust core (UniFFI), shipping on device. See docs/iOS-App.md / docs/Android-App.md.
- ~~36.25 Native integrations — CRM, Slack/Teams, Zapier/Make (spec 14.6)~~ — **won't do** (product decision 2026-07): config-CRUD stub stays; no OAuth flows / webhook dispatch planned.
- ~~36.26 Embeddable widgets (spec 14.7)~~ — **won't do** (product decision 2026-07): backend config API stays; `/widget.js` not planned.
- [x] 36.27 Per-address / per-rule delivery channel override (spec 20.1.7)

---

## Untracked — Mail Infrastructure & Integration

Items required by the spec but never added to the TODO. The Rails API has models, controllers, and tests for managing these features, but the actual infrastructure behind them does not exist.

### 37. Go MX Inbound Receiver (spec 16.2.1, P0)

Go SMTP server in `mta/cmd/mx/`. Receives inbound mail, validates domains via NATS, checks SPF/DKIM/DMARC, publishes to JetStream.

- [x] 37.1 SMTP server — accept inbound connections, EHLO, STARTTLS, SIZE, 8BITMIME, PIPELINING (spec 18.1.1, 18.1.4, 18.1.5)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 37.2 Domain verification — accept mail only for verified domains (spec 16.2.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 37.3 Per-plan size limit enforcement at SMTP time (spec 11.5.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 37.4 SPF validation on inbound (spec 18.2.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 37.5 DKIM signature verification on inbound (spec 18.2.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 37.6 DMARC evaluation on inbound (spec 18.2.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 37.7 Hand accepted messages to NATS/JetStream queue (spec 16.1.1)
  - [x] Tests  - [x] XC  - [x] Simplify

### 38. Go SMTP Outbound Sender (spec 16.2.2, P0)

Go SMTP client in `mta/cmd/smtp/`. Worker pool consumes from NATS MAIL_OUTBOUND, DKIM-signs, delivers to remote MTAs, publishes results to MAIL_DELIVERY_STATUS. Rails OutboundMailPublisher composes RFC 5322 and queues. NatsSubscriber consumes delivery results and schedules retries via Solid Queue.

- [x] 38.1 SMTP client — connect to recipient MX, deliver mail with STARTTLS (spec 18.1.1, 18.1.4)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 38.2 DKIM signing of outbound mail (spec 18.2.2, 2.3.7)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 38.3 SPF/DMARC alignment for outbound (spec 18.2.1, 18.2.3)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 38.4 Consume send jobs from NATS/JetStream queue (spec 16.1.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 38.5 Delivery status feedback — update DeliveryStatus via API/queue (spec 20.2.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 38.6 Bounce processing — parse DSN bounces, feed back to app (spec 20.2.6) — wired via NatsSubscriber → DeliveryRetryService, DsnBounceParser already existed
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 38.7 Retry with exponential backoff on transient failures (spec 20.2.3) — Go does 3 fast retries; Rails DeliveryRetryService schedules 5 slow retries via OutboundRetryJob
  - [x] Tests  - [x] XC  - [x] Simplify

### 39. NATS/JetStream Application Integration (spec 16.1.1, P0)

Go MX publishes to MAIL_INBOUND stream. Rails subscriber handles domain lookups (request-reply) and inbound message processing (threading, rules, ActionCable broadcast).

- [x] 39.1 Rails NATS subscriber — domain lookup responder + inbound message consumer (spec 16.1.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 39.2 Rails NATS consumer — process delivery status updates, bounce notifications (spec 16.1.1) — NatsSubscriber extended with MAIL_DELIVERY_STATUS consumer
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 39.3 Go MX NATS publisher — hand accepted messages to queue (spec 16.1.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 39.4 Go SMTP NATS consumer — pick up send jobs from queue (spec 16.1.1) — outbound.Consumer with MAIL_OUTBOUND stream
  - [x] Tests  - [x] XC  - [x] Simplify

### 40. Rspamd Integration (spec 11.1, P0)

`RspamdClient` calls Rspamd HTTP API from Rails inbound pipeline. Scoring gated by plan (paid only). Blocklist/allowlist enforced pre-scoring. User spam feedback trains Rspamd.

- [x] 40.1 Rspamd HTTP client — score inbound messages via Rspamd API (spec 11.1.1) — `RspamdClient#check` with score, action, symbols
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 40.2 Automatic spam classification based on score threshold (spec 11.1.2) — per-org `spam_threshold` (default 5.0). No UI writes it yet; the old `spam_aggressiveness` presets were dropped (the column default always shadowed them)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 40.3 Spam feedback loop — train Rspamd on user spam/not-spam actions (spec 11.1.3) — `spam_feedback` endpoint calls `RspamdClient#train_spam` / `#train_ham`
  - [x] Tests  - [x] XC  - [x] Simplify

### 41. S3/Garage Object Storage (spec implied by attachment handling, P0)

`S3StorageService` wraps aws-sdk-s3 for Garage/S3-compatible storage. Inbound attachments extracted from raw RFC 5322 via `mail` gem and uploaded to S3. Direct upload/download via AttachmentsController with presigned URLs.

- [x] 41.1 Configure S3-compatible backend (Garage) (spec 16.5.2) — `S3StorageService` + `config/storage.yml`, aws-sdk-s3 gem, auto bucket creation
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 41.2 Attachment upload — store to S3, return metadata (spec A7.3) — controller upload + inbound MIME extraction from `raw_message_b64`
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 41.3 Attachment download — presigned URL redirect (spec A7.2) — `GET /attachments/:id` → S3 presigned URL redirect
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 41.4 Inline image serving for HTML emails (spec 4.1.4) — same presigned URL mechanism, `content_id` for CID matching
  - [x] Tests  - [x] XC  - [x] Simplify

### 42. MX/SMTP Test Suite (spec 17.2, P0)

MX has full Go test suite with embedded NATS. Test corpus in `mta/testdata/corpus/`.

- [x] 42.1 Go test suite for MX — protocol handling, parsing, size limits, auth checks (spec 17.2.1)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 42.2 Curated email test corpus (spec 17.2.2)
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 42.3 Email-injection tool for local pipeline testing (spec 17.2.3) — `mta/cmd/mxtest` injects .eml files and corpus batches via TCP/SMTP
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 42.4 Outbound sink for local SMTP testing (spec 17.2.4) — `mta/cmd/smtpsink` + embeddable `outbound.Sink` for Go tests
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 42.5 Conformance tests — section 18 email standards (spec 17.2.6) — distributed across auth/, parser/, smtpd/, outbound/ test suites
  - [x] Tests  - [x] XC  - [x] Simplify

### 43. Performance & Load Testing (spec 17.4, P0/P1)

`mta/cmd/mxtest -load` for TCP load testing. Go benchmarks in `mta/internal/smtpd/bench_test.go`.

- [x] 43.1 MX inbound throughput/latency load tests (spec 17.4.1, P0) — `mxtest -load` with configurable concurrency + percentile reporting; `BenchmarkSMTP_SingleConnection` Go benchmark
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 43.2 SMTP outbound throughput/latency load tests (spec 17.4.2, P1) — `BenchmarkDKIMSign` + `BenchmarkSender_ToSink` in outbound/bench_test.go
  - [x] Tests  - [x] XC  - [x] Simplify

### 45. Cloud Push for Local Channels (Gmail/Office365) — see docs/Cloud-Push.md

Realtime Gmail/Office365 delivery via a Rails-backed push token mechanism, without exposing the OAuth token to cloud infra. Client creates the provider subscription (Gmail Pub/Sub watch / Graph subscription) pointing at Rails; Rails fans a content-free "go sync" signal over ActionCable.

- [x] 45.1 `ChannelPushSubscription` model + schema (mapping only, no tokens; 30-day lease) + `User#push_enabled?` gating chokepoint
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 45.2 Subscriptions controller (check/register/renew/teardown/config) + `PushWebhooksController` (Gmail OIDC/token, Microsoft validationToken+clientState) + `PushSyncChannel` + `ChannelPushBroadcaster`
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 45.3 `ChannelPushSubscriptionSweeperJob` lease GC (daily) — reclaims abandoned subscriptions
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 45.4 Engine: provider `create/renew/delete_push_subscription` (Gmail watch, Graph subscriptions) + `sync/push.rs` orchestration + local `push_subscription_state` + poll-tick renewal + IPC commands
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 45.5 Frontend: `pushSync` (PushSyncChannel + register flow), `usePushSync` (lifecycle + offline catch-up), `cloudPushPref` toggle on the Notifications tab
  - [x] Tests  - [ ] XC  - [x] Simplify
- [x] 45.6 Production hardening: Gmail Pub/Sub OIDC JWT verification (googleauth IDTokens/JWKS in GmailPushVerifier), Terraform for the topic + push subscription (`deploy/gcp-pubsub/`), paid-plan gating flipped (`User#push_enabled?` = any paid org; `PUSH_FREE_FOR_ALL=1` escape hatch)

### 44. Deployment Infrastructure

Live — `deploy/` holds the Terraform (modules + per-env roots + Cloudflare DNS); prod (`inbox2-prod`) auto-deploys on push to `main`. See docs/Deployment.md + docs/Go-Live.md.

- [x] 44.1 Terraform configuration for Rancher/K8s cluster
- [x] 44.2 Kubernetes manifests via Terraform modules for all services (spec 16.5.3)
- [x] 44.3 CI/CD pipeline — GitLab CI build → kubectl set image on `main`

---

## 46. Deliverability Hardening — see docs/Mail-Deliverability.md

Closing the gaps between "mail sends" and "mail is trusted + we learn when it isn't".

- [x] 46.1 DKIM signing end-to-end — central platform key (`DkimKey`, `dkim:generate` rake task), real `private_key_pem` carried in the outbound NATS payload so the Go sender signs `d=<org domain>`. Previously the payload key was always empty.
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 46.2 Suppression list — `SuppressionEntry` model, enforced in `OutboundMailPublisher` (drops suppressed recipients; all-suppressed → failed, never queued), populated from hard bounces, complaints, and address-shaped 5xx.
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 46.3 Inbound DSN bounce routing — `InboundReportRouter` parses DSN reports, matches the originating `DeliveryStatus`, updates it, and suppresses hard bounces. `DsnBounceParser` was previously orphaned (zero callers).
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 46.4 ARF complaint handling — feedback-report parsing → suppression.
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 46.5 Inbound idempotency — dedupe by `Message-ID` so at-least-once NATS redelivery (post-insert nak) can't create duplicate messages. _Root cause of observed duplicate-on-receive._
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 46.6 `receiving_mail` promotion — set on first inbound message (the documented transition was previously dead).
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 46.7 Retry double-status fix — `OutboundRetryJob` reuses the existing `DeliveryStatus` instead of creating a new one per retry.
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 46.8 Delivery-failure notifications (supersedes the overstated 36a.9) — `delivery_failure` Notification kind + `DeliveryFailureNotifier`, fired from a DeliveryStatus status-change callback (all transition paths, no re-notify on failed→bounced).
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 46.9 MTA-STS outbound enforcement — mta/internal/mtasts (TXT discovery + HTTPS fetch + max_age/stale caching); enforce mode = policy-matching MX only, PKIX-verified TLS mandatory, downgrade → transient failure.
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 46.10 TLS-RPT + DMARC `rua` report ingestion — InboundReportRouter parses both (gzip/zip/xml) into MailAuthReport rows; surfaced at `GET /orgs/:org/deliverability/auth-reports`.
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 46.11 IP reputation — startup FCrDNS/PTR self-check (SMTP_PUBLIC_IP), warmup daily budget (SMTP_WARMUP_START), per-recipient-domain concurrency+rate pacing (mta/internal/outbound/reputation.go).
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 46.12 Prometheus metrics for MX/SMTP — mta/internal/metrics text-exposition registry on MX_METRICS_ADDR / SMTP_METRICS_ADDR.
  - [x] Tests  - [x] XC  - [x] Simplify
- [x] 46.13 MX-edge spam defense — smtpd/edge.go: opt-in DNSBL (MX_RBL_ZONES), per-IP connection-rate limit, PTR-gated greylisting (MX_GREYLIST=off to disable).
  - [x] Tests  - [x] XC  - [x] Simplify

## 47. Code audit 2026-10-18 — decisions

Walked item by item with Waseem on 2026-10-18 (full-repo audit: Rails, web, iOS, Android, Rust core; slopo/jscpd/flay/brakeman + three review passes). The report itself is deliberately not persisted. Decisions and scope:

- [x] 47.1 Invite acceptance moves to a hashed single-use invite token mailed to the invitee; the membership key stops granting anything. **Full build.**
- [x] 47.2 SAML identity binding: `saml_identities` table + explicit link step for existing users, provision on first SSO login otherwise; no more username-local-part matching. **Full build.**
- [x] 47.3 Calendar invitations: `organizer_email` dropped from the permit lists (no client sends it) and `CalendarInviteDispatch` refuses a From the acting member cannot send as. **Full build.**
- [x] 47.4 SaaS operator plane: header auth requires an explicit env flag even in production, `/saas/*` throttled, prod gets `SAAS_IP_ALLOWLIST` + `TRUSTED_PROXIES`. **Ingress mTLS deferred** to its own infra task (docs/SaaS.md still describes the target).
- [x] 47.5 Every org read goes through `visible_to`/`not_private`: cable channels, drafts index/destroy, attachments show/create, data export, MCP agent reads honour domain grants, views/spaces counts, org activity, sync tombstones. **All seven.**
- [x] 47.6 Android parity: inbox/badge queries ported from iOS (folder-set, no `labels LIKE`), on-device LLM load foreground-gated + background sync skips on-device triage, barge-in armed before TTS. **Car barge-in (both platforms) deferred** until the Bridge session is lifted out of the views.
- [x] 47.7 `billing_email`: unique case-insensitive index + deterministic lookups. **Narrow**; full verification flow deferred (decided 2026-10-18: SAML link step relies on the signed-in session, not the address).
- [x] 47.8 Hardening: SSRF guard ranges + pinned webhook/SMTP-test connects, throttles on the unthrottled auth/invite/tracking/saas routes, Turnstile fails loudly in prod, identity-key replacement requires re-auth. **Tracking endpoint auth + opens scoping deferred** (protocol change for local channels).
- [x] 47.9 N+1/perf: label-filter tag truncation, thread-detail opens/links preload, shared index preload set, partial unread index, attendee email expression index, no writes on `GET /plans`, Medium N+1 sites, SendQuota/view_suggester in SQL, Empty Trash as a batched job, prosopite in test. **Everything.**
- [x] 47.10 Dedup, targeted: one `Organization.provision!`, `Membership` scopes, delete the alias/health/duplicate-destroy endpoints and the notification-preferences stub, replay nonce on the conferencing OAuth callback. **`require_role!`/rescue sweep and ImageAssets concern deferred** to when those files are next touched.
- [x] 47.11 Web: Spaces create/invite modal wired to real APIs, `Modal` dialog semantics + focus, keyboard paths for the two click-only controls, `useDismiss` sweep, one NotificationCard, one priority-tag helper, catalog palette to tokens, `localFirstApi` import rule, token-literal ratchet test + jsx-a11y, and the full token sweep (Groovebox hex, `#ffb03a`, MeetPage sizes, z-index literals). **Recommended + full sweep.**
- [x] 47.12 Mobile: Android calendar reads off Main, slug resolution ported, WebView proxy allowlist, iOS content logs no longer `.public`, read-aloud exception documented, stale SecureStore comments, `AppFont.ui` sweep, shared buttons adopted, duplicate helpers, and the view splits (InboxListView, MessageCard, SettingsView, BridgeView→session; ReaderScreen, InboxScreen, CalendarSheets, RootTabs). **Everything.**

Landed 2026-10-18, all pushed to `main`: 47.1–47.12. Visual pass done over Chrome DevTools (local Rails +
Vite), the Android emulator and the rebuilt desktop app; iOS is build-verified (the iPhone was not reachable
over the air that day — install with `bin/ios-deploy-device` when it is).

Still open from this audit (decided deferrals, in priority order). Each was checked against the code on
2026-11-09; none has been closed since 2026-10-18.
- Ingress mTLS for `/api/v1/saas` (47.4). The operator plane is **closed** in prod, and should stay closed
  until the ingress does mTLS: `.pl.yaml` sets none of `SAAS_ALLOW_HEADER_AUTH`, `SAAS_IP_ALLOWLIST` and
  `TRUSTED_PROXIES`. **Do not set `SAAS_ALLOW_HEADER_AUTH` first.** It makes Rails trust the
  `ssl-client-verify` / `ssl-client-fingerprint` headers, so before it goes on, the ingress in front of the
  api role must (1) verify the client certificate itself and (2) strip any client-supplied `ssl-client-*`
  headers. Without both, anyone at an allowlisted address can send the headers by hand and the fingerprint is
  a bare bearer secret for the cross-tenant API. Whether Pushleft's ingress can do this is not yet checked.
  Once it does: set the three in `.pl.yaml` `env:` (or `pl secrets set` plus the `secrets:` list) and run
  `pl up --production`. This bullet used to point at `deploy/prod/terraform.tfvars`, which is dead Rancher
  config since 2026-11.
- Car barge-in on CarPlay and Android Auto (47.6): the iOS `BridgeSession.speak` already arms the spotter; the
  car delegates (`CarPlaySceneDelegate.swift`, `BridgeCarScreen.kt`) still call `speaker.speak` directly.
- Tracking endpoints: `ink_` auth on register/verify-host and scoping `opens` to the owning channel (47.8).
  `tracking_controller.rb` is still unauthenticated and looks opens up by token alone.
- Full `billing_email` verification flow (47.7): pending column + mailed confirmation + verified_at. Only the
  column and its unique index exist.
- `require_role!` raise-into-`rescue_from` sweep (47.10): it still renders, and callers still guard with
  `return if performed?`. The `ImageAssets` concern itself exists (since 2026-06, four controllers include
  it); what is left there is whatever the audit wanted moved into it, which this list never named.
- Prosopite allow-list (api/spec/rails_helper.rb), 11 entries, unchanged: `user_offboarder`, `disk/node_ops`,
  `disk/sealing`, `disk/lifecycle`, `mobile_push_sender` (the whole file; one EXISTS per member per inbound
  message in `conversation_recipients`, already marked ponytail), `saas/dashboard_metrics`, the three
  `ensure_*` seeders, `Disk::Share#assign_slug`, `Disk::Event.record!`. Each is a per-row write loop or a
  documented ceiling; remove an entry when it is batched.
- Web: 70 `jsx-a11y` warnings on 2026-11-09 (67 on 2026-10-18; left as warnings), the off-grid font sizes in
  MeetPage/console (13.5/12.5/10.5px etc.), TouchStrip's theme-independent rainbow and the `#7b6cf6` bento
  violet (no token exists; still a fallback in `DnsVerify.jsx` and `SpaceDashboard.module.css`) — design
  calls, not auto-fixes.

## 48. Open points walked 2026-11-09 — decisions

Walked one at a time with Waseem on 2026-11-09, after the plans were checked against the code the same day
(Disk spec, Lore, mail import, section 47's deferrals, MX sync, payments). 29 points plus four follow-ups.
A box is ticked when the work is built and verified, not when it is decided.

Disk (docs/plans/disk-spec.md)
- [x] 48.1 E2E suite: bring all 162 tests up to the current UI, run all three browsers, tick what passes and
  un-tick any ticked box that now fails; add a pre-push step that runs the suite only when Disk files change.
- [ ] 48.2 Exact-view engine: **download on the first Office file**, not when Disk opens (reverses the automatic
  download of `c3870766`). The settings list stays removed. Rewrite the F5b Accept lines to this flow.
- [ ] 48.3 Engine gaps, **two fixes**: a rendition is marked present only once its upload lands; "Try again"
  after a failed download. Reworded, not built: page position into exact view, "always" without a click.
  Accepted limit: a converted file stays cached after access to it is revoked (cleared on sign-out).
- [x] 48.4 Engine in the desktop app: **dropped.** The desktop opens Disk in the browser.
- [ ] 48.5 "Hide the Download button": the caveat sentence **stays removed**; Accept line and test follow.
  Leaves unsupported: the spec's promise that the dialog says hiding does not stop saving.
- [ ] 48.6 Send as Disk link: offered from **25 MB** (the send cap), **for files from Disk and from the
  computer**; a computer file over 25 MB is uploaded to the member's Disk and linked.
- [ ] 48.7 Org export: **team shares only**; no `C/<member>/` in the zip or the manifest. Plus **"Export my
  disk"**: one button that zips a person's whole `C:\`.
- [ ] 48.8 Backups: decided twice. First "wait for the first customer"; then, because 48.16 moves lalaaji.com,
  **a nightly copy of the mail attachment store and the Disk bucket into a second bucket, and one rehearsed
  restore (a database row and a deleted file), before the MX switch.** The database keeps Pushleft's daily
  backup; no off-platform database copy.
- [x] 48.9 Terms and privacy: **the Disk section only** (R2 in the EU, 30-day trash, sealed files as
  ciphertext). Leaves open: the twelve `<Fill>` placeholders (KVK number, address, hosting region, retention
  periods, dunning period, court district).
- [x] 48.10 Disk metrics: **a Disk card on the admin CLI dashboard now**, though it reaches production only
  once 48.18 is done.
- [ ] 48.30 Voice-dna pass over all of Disk's customer-facing copy, labels included, each read with the
  content around it (asked 2026-11-09, during the walk).

Lore (docs/plans/lore.md)
- [x] 48.11 Done on a shared MX domain: **per-member for the personal buckets** (read later, FYI, receipts,
  notifications hide for the ticking member only); work items (reply, pay, review) stay an archive for the
  team. New table, a sync change, every client.
- [x] 48.12 Send to…: **store and show the reference** on the item as a chip with its link. No status
  following: tools are still never called automatically.
- [ ] 48.13 Mobile: **undo after a tick on iOS and Android, and the Lore Live Activity** ("Next up · Done") on
  iPhone. Built 2026-11-09 and compiled (opt-in lock icon on the Next up card); not yet run on a phone.
- [ ] 48.14 Mobile: **Send to… on iOS and Android.** The miner's model pass stays on the desktop and
  `engine_daemon`. Leaves unsupported: projects and relations mined from Gmail/Microsoft/IMAP mail on a phone
  with no desktop running. Built 2026-11-09 and compiled; a real sign-in and Create not yet run on a phone.
- [x] 48.15 Entities and facts: **full editing** (rename, change kind, edit a fact, merge, remove), both
  stores, with removals remembered so the miner does not bring them back.

Mail import (docs/plans/mail-import.md)
- [ ] 48.16 **Full move of lalaaji.com**: every mailbox imported, then the MX records switched. Needs Waseem
  in the Google admin console (steps in the plan). 48.8 comes first.
- [x] 48.17 Private labels: **rename, delete and "Share with the team" (admins) on web and desktop.** Phones
  keep list, create and apply.

Audit deferrals (section 47)
- [x] 48.18 Operator plane: **`/saas` on a second port that is never routed publicly, reached through
  `pl tunnel`.** Replaces the ingress-mTLS plan of 47.4; prove the public route cannot reach the port before
  switching it on.
- [ ] 48.19 Car barge-in: **CarPlay and Android Auto both** go through the session's speak. Android Auto on
  the emulator; CarPlay needs a drive by Waseem.
- [x] 48.20 Open tracking: **a secret for reading opens** (the pixel carries its hash, so a recipient cannot
  read other recipients' opens; no account needed) **and a linked account to register a custom tracking
  host.** Old tokens stay readable until every client has shipped. Per device, decided 2026-11-09: the secret
  has no shared home for Gmail/IMAP mail, so opens read back only on the device that sent the mail.
- [x] 48.21 Contact email: **confirm on change.** A new address is pending until its mailed link is clicked;
  resets and notices go only to a confirmed address; waitlist-invite and existing addresses count as confirmed.
- [x] 48.22 Housekeeping: `require_role!` raises into one `rescue_from`; the 70 `jsx-a11y` warnings go to
  zero and become errors; off-grid font sizes move onto the type scale; the bento violet gets a token.
  **The Touch Strip's rainbow stays as it is** (Waseem, 2026-11-09).

MX sync and sealed mail (docs/MX-Sync.md, docs/E2EE.md)
- [x] 48.24 Seal format first: **the part's role goes into the associated data** as a new scheme version;
  all three readers (Go, JavaScript, Rust) accept both versions before any writer switches.
- [ ] 48.23 Sealed mail on phones, after 48.24: **identity unlock in the Rust core**, an unlock screen on iOS
  and Android, **and unlock with Face ID / fingerprint** after the first passphrase.
- [x] 48.25 Stale documents corrected: Feature-Spec 16.7 (as v1.11), TODO section 35, SaaS.md, the Disk build
  guide, the GTM facts ledger, CLAUDE.md's CarPlay note.

Payments (no plan document; Feature-Spec section 13)
- [x] 48.26 Pricing model: **the three tiers as built** (Free; Startup, 2 domains and 2 collaborators; Serial
  Entrepreneur, unlimited). The spec and the GTM ledger are revised to match; the pricing page loses the
  100 MB send claim and gains Disk storage. Leaves unsupported: spec 13.1.2's flat plan with everything
  unlimited, and "never per seat" taken literally (Startup caps collaborators).
- [x] 48.31 Currency: **euros** (€19.99 and €49.99, excluding VAT) in code, site and ledger.
- [ ] 48.27 **Stripe**: hosted Checkout, the customer portal for cards and invoices, webhooks driving the
  subscription state, Stripe Tax. Needs Waseem's Stripe account and test keys.
- [ ] 48.28 Lifecycle: **14-day trial without a card; about two weeks of retries with mail to the confirmed
  address; then Free limits with a soft fallback**: over-limit domains keep receiving mail and become
  read-only. To settle in the build: what a sealed domain does on Free.
- [ ] 48.29 **Annual billing, two months free** (ten times the monthly price), with a monthly/yearly toggle
  and proration on a mid-year change.
