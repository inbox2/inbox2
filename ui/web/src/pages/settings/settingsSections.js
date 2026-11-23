// The settings tabs, shared by the desktop SettingsPage sidebar and the phone
// More screen (src/mobile/MobileMore.jsx), which lists the same sections.
//   desktop     — only in the Tauri app
//   hideDesktop — never in the Tauri app
//   org         — needs a signed-in inbox2 org (hits /orgs/:id/*)
//   admin       — managed by org admins only (the API refuses members), so
//                 hidden from members rather than shown as controls that 403
//   mailClients — only when the org has mail clients switched on (docs/Mail-Clients.md)
//   macOnly     — only in the Mac app
//   inConsole   — has its page in the web console (the admin place, via the
//                 avatar menu's Admin settings button), so not in the desktop app.
//                 Other admin sections stay until the console has them.
export const ALL_SECTIONS = [
  // General
  { key: 'preferences', label: 'Preferences', icon: 'gear', group: 'General' },
  { key: 'account', label: 'Account & profile', icon: 'person.fill', group: 'General' },
  { key: 'accounts', label: 'Connected accounts', icon: 'link', group: 'General' },
  // Billing & plan lives in the /console console (top-level section), not here —
  // same move as team management. See pages/console/AdminSyncs.jsx (#billing).
  { key: 'theme', label: 'Theme', icon: 'photo', group: 'General' },
  // Workspace — these are MX/org-backed (they hit /orgs/:id/* APIs), so they only
  // apply when signed into an inbox2 domain. `org: true` hides them in local
  // standalone mode (no org), where fetching would 401 against /orgs/null/*.
  // Team / user management lives in the /console console (People view), not here.
  // Spaces is MX server-side AI classification — not available in the desktop
  // app, so hide it there even when signed into an org.
  { key: 'spaces', label: 'Spaces', icon: 'square.grid.2x2', group: 'Workspace', org: true, hideDesktop: true },
  // The org's Jev triage labels — MX, same scoping as Spaces.
  { key: 'triage-labels', label: 'Triage labels', icon: 'tag', group: 'Workspace', org: true, hideDesktop: true },
  { key: 'rules', label: 'Routing rules', icon: 'arrow.triangle.branch', group: 'Workspace', org: true, admin: true, inConsole: true },
  // Meet links + conferencing (docs/Calendar.md) — per-member, so it lives here
  // rather than in the console.
  // Mail signatures, the member's own and the admin's per domain (spec 8.1.7).
  { key: 'signatures', label: 'Signatures', icon: 'signature', group: 'Workspace', org: true },
  { key: 'scheduling', label: 'Scheduling', icon: 'calendar', group: 'Workspace', org: true },
  // IMAP and SMTP for Outlook, Apple Mail, Thunderbird: the member's own app passwords.
  // Disk in Finder (docs/Disk-Sync.md): the File Provider extension's switch and settings. Mac app only.
  { key: 'disk', label: 'Disk', icon: 'externaldrive', group: 'Workspace', org: true, desktop: true, macOnly: true },
  { key: 'mail-clients', label: 'Mail clients', icon: 'envelope.open', group: 'Workspace', org: true, mailClients: true },
  { key: 'webhooks', label: 'Webhooks', icon: 'bolt.fill', group: 'Workspace', org: true, admin: true },
  // SSO is org sign-in config for admins — not a desktop-client concern.
  { key: 'sso', label: 'Single sign-on', icon: 'person.badge.key', group: 'Workspace', org: true, admin: true, hideDesktop: true },
  // Intelligence
  { key: 'enrichment', label: 'Enrichment', icon: 'person.badge.plus', group: 'Intelligence' },
  { key: 'ai-features', label: 'On-device AI', icon: 'brain', group: 'Intelligence', desktop: true },
  { key: 'triage', label: 'Triage & sync', icon: 'sparkles', group: 'Intelligence', desktop: true },
  { key: 'local-rules', label: 'Auto rules', icon: 'line.3.horizontal.decrease', group: 'Intelligence', desktop: true },
  // Outbound MCP client — Lore's "Send to…" (docs/MCP-Client.md). Rust core, desktop only.
  { key: 'mcp-apps', label: 'Connected apps (MCP)', icon: 'link', group: 'Intelligence', desktop: true },
  // Security & Compliance
  { key: 'spam', label: 'Spam & filtering', icon: 'nosign', group: 'Security & Compliance', org: true, admin: true },
  { key: 'logs', label: 'App logs', icon: 'terminal', group: 'Security & Compliance' },
  // Desktop-only: shows the app version and drives the auto-update flow.
  { key: 'about', label: 'About', icon: 'info.circle', group: 'Security & Compliance', desktop: true },
];
