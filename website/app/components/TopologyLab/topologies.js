/* ==========================================================================
   topologies.js — the inbox2 system, modelled as authored isometric scenes
   that the canvas renderer (canvas-iso.client.js) draws. One scene per
   deployment shape (open-source · Cloud MX · self-hosted cloud · on-prem).

   Coordinates live on a logical grid:
     x → east   (screen right-ish in iso)
     y → north  (screen left-ish in iso)
     z → height (stacks lift off the ground plane)
   The renderer projects these into isometric space; nothing here is
   screen-space. Drag pieces in the dev UI and use "Copy positions" to author
   new coordinates (see canvas-iso's exportLayout).

   `zones` draw labelled dotted boundaries on the floor (a hosting boundary —
   inbox2 Cloud, your cloud, on-prem, your device). `NODE_DESC` feeds the
   hover popup; it's keyed by node id so it's shared across scenes.
   ========================================================================== */

/** Node families — each maps to a colour + silhouette in the renderers. */
export const KIND = {
  client: "client",
  gateway: "gateway",
  queue: "queue",
  server: "server",
  store: "store",
  external: "external",
  ai: "ai",
  pool: "pool",
  person: "person",
  hook: "hook",
};

/**
 * Per-kind view config: colour palette + the default block silhouette for
 * that family (a node may still override it with its own `shape`). Defaults
 * to a cube when `shape` is unset.
 */
export const KIND_STYLE = {
  client: { hex: "#3a7ef4", glow: "#9cc2ff", label: "Client", shape: "device" },
  gateway: { hex: "#22c3a6", glow: "#8af0df", label: "Gateway" },
  queue: { hex: "#c98a2b", glow: "#ffd591", label: "Queue" },
  server: { hex: "#7c6cff", glow: "#c3bcff", label: "Service" },
  store: { hex: "#8a8f96", glow: "#d6dbe2", label: "Store" },
  external: { hex: "#e2566f", glow: "#ffb3c0", label: "External", shape: "cloud" },
  ai: { hex: "#16c0e6", glow: "#9be9fb", label: "AI" },
  pool: { hex: "#2b6cde", glow: "#cfe0ff", label: "Domain inbox" },
  person: { hex: "#46c06f", glow: "#b7f0c8", label: "Person" },
  hook: { hex: "#b06cff", glow: "#dcc3ff", label: "Webhook" },
};

/** Hover-popup copy, keyed by node id (shared across scenes). */
export const NODE_DESC = {
  internet: "The public internet: senders and recipients out in the world.",
  gmail: "A Gmail account, synced directly over its API. It stays client-side.",
  o365: "An Office 365 or Outlook account, synced over Graph on your device.",
  imap: "Any IMAP mailbox, synced directly. It never passes through inbox2.",
  esp: "Your chosen email service provider (SES, SendGrid, Postmark…) sends the signed outbound mail.",
  mx: "MX inbound receiver: accepts mail for your domain, checks SPF, DKIM and DMARC, and queues it.",
  smtp: "SMTP outbound: DKIM-signs your mail and delivers it, directly or through an ESP.",
  nats: "NATS JetStream: the durable queue between the receiver and the API.",
  pg: "PostgreSQL: stores conversations, members and rules.",
  api: "The API: runs sign-in, routing rules and the domain's inbox.",
  s3: "Garage: S3-compatible object storage for attachments and files.",
  pool: "The domain's inbox: all mail in one place, and everyone gets their own views.",
  engine: "The Rust sync engine: runs on your device and pulls each mailbox into local SQLite.",
  sqlite: "Local SQLite: your inbox as a file on your own disk, readable offline.",
  ondevice: "On-device AI: classification and summaries that stay on your machine.",
  desktop: "The desktop app for macOS, Windows and Linux, built on Tauri over the shared core.",
  ios: "The native iOS app: SwiftUI over the same Rust core.",
  android: "The native Android app: Jetpack Compose over the same Rust core.",
};

/**
 * Optional vendor list drawn vertically beside a node (e.g. the supported
 * ESPs next to the ESP node). Each row = small logo + name; `logo` optional.
 * Keyed by node id.
 */
export const NODE_VENDORS = {
  esp: [
    { name: "Amazon SES", logo: "/assets/logos/ses.svg" },
    { name: "SendGrid", logo: "/assets/logos/sendgrid.svg" },
    { name: "Mailgun", logo: "/assets/logos/mailgun.svg" },
    { name: "Postmark", logo: "/assets/logos/postmark.svg" },
    { name: "Custom SMTP" },
  ],
};

/**
 * Brand icons for nodes drawn with shape "logo" (an image path) or "glyph"
 * (a character). Keyed by node id and decoupled from coordinates, so the
 * dev "Copy positions" round-trip (which only emits coords + shape) is safe.
 */
export const NODE_ICON = {
  gmail: "/assets/logos/gmail.svg",
  o365: "/assets/logos/office365.svg",
  imap: "/assets/logos/imap.svg",
};

const n = (id, label, kind, x, y, z = 0, shape = null) => ({
  id, label, kind, x, y, z, ...(shape ? { shape } : {}),
});
const e = (from, to, kind = "data") => ({ from, to, kind });
const zone = (id, label, tint, nodes) => ({ id, label, tint, nodes });

// zone boundary tints (hosting environments)
const TINT = {
  inbox2: "#2e86f0", // inbox2 cloud — electric blue
  cloud: "#22c3a6", // your own cloud — teal
  onprem: "#d0a050", // on-prem — amber
  device: "#8a8f96", // your device — grey
};

/* --------------------------------------------------------------------------
   1 — Open source: clients sync external mailboxes straight to local SQLite.
   No inbox2 cloud at all; on-device AI; offline-first.
   -------------------------------------------------------------------------- */
const openSource = {
  id: "open-source",
  label: "Open source",
  sub: "Local · no cloud",
  tier: "Free",
  blurb:
    "The free apps connect Gmail, Microsoft 365 and IMAP straight into a local SQLite file on your device.",
  zones: [
    zone("device", "Your device", TINT.device, [
      "engine", "sqlite", "ondevice", "desktop", "ios", "android",
    ]),
  ],
  nodes: [
    n("gmail", "Gmail", KIND.external, -2.0, -2.0, 1, "logo"),
    n("o365", "Office 365", KIND.external, 0.0, -2.5, 1, "logo"),
    n("imap", "IMAP", KIND.external, 2.0, -2.0, 1, "logo"),
    n("engine", "Sync engine", KIND.server, 0.0, 0.5, 1),
    n("ondevice", "On-device AI", KIND.ai, 2.0, 0.5, 1),
    n("sqlite", "Local SQLite", KIND.store, -2.0, 0.5, 1),
    n("desktop", "Desktop", KIND.client, -1.5, 3.0, 1, "monitor"),
    n("ios", "iOS", KIND.client, 0.0, 3.2, 1, "phone"),
    n("android", "Android", KIND.client, 1.5, 3.0, 1, "phone"),
  ],
  edges: [
    e("gmail", "engine", "sync"),
    e("o365", "engine", "sync"),
    e("imap", "engine", "sync"),
    e("engine", "sqlite", "data"),
    e("engine", "ondevice", "ai"),
    e("sqlite", "desktop", "read"),
    e("sqlite", "ios", "read"),
    e("sqlite", "android", "read"),
  ],
};

/* --------------------------------------------------------------------------
   2 — Cloud MX: domain mail into the inbox2-hosted domain inbox, out to every device.
   (The iterated layout — coordinates are the authored ones.)
   -------------------------------------------------------------------------- */
const cloudMx = {
  id: "cloud-mx",
  label: "Cloud MX",
  sub: "inbox2 hosted",
  tier: "Free / Paid",
  blurb:
    "Point your domain's MX at inbox2. We receive and queue inbound mail and file it in the domain's inbox, and we host all of it.",
  zones: [
    zone("inbox2", "inbox2 Cloud", TINT.inbox2, [
      "mx", "smtp", "nats", "pg", "api", "s3", "pool",
    ]),
  ],
  nodes: [
    n("internet", "Internet", KIND.external, 0.25, -2.0, 1, "cloud"),
    n("mx", "MX inbound", KIND.gateway, -0.5, 0.25, 1),
    n("smtp", "SMTP out", KIND.gateway, 0.5, 0.25, 1),
    n("nats", "NATS", KIND.queue, 2.0, 0.25, 1),
    n("pg", "Postgres", KIND.store, -0.25, 2.0, 1),
    n("api", "API", KIND.server, 1.75, 2.0, 1),
    n("s3", "Garage S3", KIND.store, 3.5, 2.0, 1),
    n("pool", "Domain inbox", KIND.pool, 1.75, 3.75, 3),
    n("desktop", "Desktop", KIND.client, -0.25, 5.25, 1, "monitor"),
    n("ios", "iOS", KIND.client, 1.0, 5.25, 1, "phone"),
    n("android", "Android", KIND.client, 2.0, 5.25, 1, "phone"),
  ],
  edges: [
    e("internet", "mx", "mail"),
    e("mx", "nats", "mail"),
    e("nats", "api", "data"),
    e("api", "pg", "data"),
    e("api", "s3", "data"),
    e("api", "pool", "data"),
    e("pool", "desktop", "sync"),
    e("pool", "ios", "sync"),
    e("pool", "android", "sync"),
    e("api", "smtp", "mail"),
    e("smtp", "internet", "mail"),
  ],
};

/* --------------------------------------------------------------------------
   3 — Self-hosted cloud: the same stack, but running in YOUR cloud account.
   Outbound goes through your chosen ESP.
   -------------------------------------------------------------------------- */
const selfHostedCloud = {
  id: "self-hosted-cloud",
  label: "Self-hosted cloud",
  sub: "Your cloud · ESP out",
  tier: "Advanced",
  blurb:
    "Run the whole inbox2 stack in your own cloud account, with the same inbox and the same apps.",
  zones: [
    zone("cloud", "Your cloud", TINT.cloud, [
      "mx", "smtp", "nats", "pg", "api", "s3", "pool",
    ]),
  ],
  nodes: [
    n("internet", "Internet", KIND.external, 0.25, -2.0, 1, "cloud"),
    n("esp", "ESP", KIND.gateway, 2.0, -1.5, 1),
    n("mx", "MX inbound", KIND.gateway, -0.5, 0.25, 1),
    n("smtp", "SMTP out", KIND.gateway, 0.5, 0.25, 1),
    n("nats", "NATS", KIND.queue, 2.0, 0.25, 1),
    n("pg", "Postgres", KIND.store, -0.25, 2.0, 1),
    n("api", "API", KIND.server, 1.75, 2.0, 1),
    n("s3", "Garage S3", KIND.store, 3.5, 2.0, 1),
    n("pool", "Domain inbox", KIND.pool, 1.75, 3.75, 3),
    n("desktop", "Desktop", KIND.client, -0.25, 5.25, 1, "monitor"),
    n("ios", "iOS", KIND.client, 1.0, 5.25, 1, "phone"),
    n("android", "Android", KIND.client, 2.0, 5.25, 1, "phone"),
  ],
  edges: [
    e("internet", "mx", "mail"),
    e("mx", "nats", "mail"),
    e("nats", "api", "data"),
    e("api", "pg", "data"),
    e("api", "s3", "data"),
    e("api", "pool", "data"),
    e("pool", "desktop", "sync"),
    e("pool", "ios", "sync"),
    e("pool", "android", "sync"),
    e("api", "smtp", "mail"),
    e("smtp", "esp", "mail"),
    e("esp", "internet", "mail"),
  ],
};

/* --------------------------------------------------------------------------
   4 — Self-hosted on-prem: everything on-prem EXCEPT the MX inbound receiver,
   which stays in inbox2 Cloud. Outbound via your ESP. Two boundaries.
   -------------------------------------------------------------------------- */
const selfHostedOnPrem = {
  id: "self-hosted-onprem",
  label: "On-prem",
  sub: "On-prem + hosted MX",
  tier: "Advanced",
  blurb:
    "Run inbox2 in your own building. The MX inbound receiver stays in inbox2 Cloud so you never expose port 25, everything else runs on-prem, and outbound mail goes through your ESP.",
  zones: [
    zone("inbox2", "inbox2 Cloud", TINT.inbox2, ["mx"]),
    zone("onprem", "On-prem", TINT.onprem, [
      "smtp", "nats", "pg", "api", "s3", "pool",
    ]),
  ],
  nodes: [
    n("internet", "Internet", KIND.external, 0.25, -2.5, 1, "cloud"),
    n("mx", "MX inbound", KIND.gateway, -1.5, -1.0, 1),
    n("esp", "ESP", KIND.gateway, 2.2, -1.5, 1),
    n("nats", "NATS", KIND.queue, 2.0, 0.5, 1),
    n("smtp", "SMTP out", KIND.gateway, 0.5, 0.5, 1),
    n("pg", "Postgres", KIND.store, -0.25, 2.25, 1),
    n("api", "API", KIND.server, 1.75, 2.25, 1),
    n("s3", "Garage S3", KIND.store, 3.5, 2.25, 1),
    n("pool", "Domain inbox", KIND.pool, 1.75, 4.0, 3),
    n("desktop", "Desktop", KIND.client, -0.25, 5.5, 1, "monitor"),
    n("ios", "iOS", KIND.client, 1.0, 5.5, 1, "phone"),
    n("android", "Android", KIND.client, 2.0, 5.5, 1, "phone"),
  ],
  edges: [
    e("internet", "mx", "mail"),
    e("mx", "nats", "mail"),
    e("nats", "api", "data"),
    e("api", "pg", "data"),
    e("api", "s3", "data"),
    e("api", "pool", "data"),
    e("pool", "desktop", "sync"),
    e("pool", "ios", "sync"),
    e("pool", "android", "sync"),
    e("api", "smtp", "mail"),
    e("smtp", "esp", "mail"),
    e("esp", "internet", "mail"),
  ],
};

export const TOPOLOGIES = [openSource, cloudMx, selfHostedCloud, selfHostedOnPrem];

/** Quick lookup of a node by id within a topology. */
export const indexNodes = (topo) =>
  topo.nodes.reduce((m, node) => ((m[node.id] = node), m), {});
