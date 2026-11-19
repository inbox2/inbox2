import { initialsDataUri } from './initialsIcon';

// External-channel provider types — the single source for the `provider_type`
// string values (mirrors the Rust sync engine's adapter ids). Never inline
// 'gmail' / 'microsoft' / 'imap' as raw literals; reference these instead.
// (Not to be confused with `lib/providers/index.js`, the code-split Tauri
// provider-action IPC layer — that one is dynamic-import only.)
export const PROVIDER = {
  // The in-domain MX workspace (a Rails org), not an external sync channel.
  INBOX2: 'inbox2',
  GMAIL: 'gmail',
  MICROSOFT: 'microsoft',
  IMAP: 'imap',
  // Meta BYOK channels (see docs/Cloud-Push.md Meta). Mirror the Rust
  // ProviderType ids: instagram | messenger | whatsapp.
  INSTAGRAM: 'instagram',
  MESSENGER: 'messenger',
  WHATSAPP: 'whatsapp',
  // Not yet a live sync channel — reserved so brand theming / icons resolve the
  // moment a `threads` provider/channel lands (see "Threads future channel").
  THREADS: 'threads',
};

// The Meta channel provider ids, for grouping/branching.
export const META_PROVIDERS = [PROVIDER.INSTAGRAM, PROVIDER.MESSENGER, PROVIDER.WHATSAPP];

// True when a conversation/account belongs to a social channel (chat-style
// rendering) rather than email or the in-domain MX workspace. The single
// predicate every social-vs-email render branch keys off.
export const isSocial = (providerType) => META_PROVIDERS.includes(providerType);

// Meta event discriminators the sync engine's normalizer (meta_normalize.rs)
// stamps onto conversations/messages: the surface (`channel`) and the event
// `kind`. One Page account carries both messenger DMs and facebook comments, so
// `channel` ≠ provider type. Mirror the Rust constants — never inline the raw
// strings.
export const META_CHANNEL = {
  MESSENGER: 'messenger',
  FACEBOOK: 'facebook',
  INSTAGRAM: 'instagram',
  WHATSAPP: 'whatsapp',
  THREADS: 'threads',
};
export const META_KIND = {
  DM: 'dm',
  COMMENT: 'comment',
  MENTION: 'mention',
  POSTBACK: 'postback',
};

// Brand icon (public/ path) per provider type — single source so account lists,
// switchers, and the add-account picker stay in sync. Unknown types fall back to
// the generic mail icon.
export const PROVIDER_ICON = {
  [PROVIDER.INBOX2]: '/logo-mark.png',
  [PROVIDER.GMAIL]: '/channels/gmail.svg',
  [PROVIDER.MICROSOFT]: '/channels/office365.svg',
  [PROVIDER.IMAP]: '/channels/imap.svg',
  [PROVIDER.INSTAGRAM]: '/channels/instagram.svg',
  [PROVIDER.MESSENGER]: '/channels/messenger.svg',
  [PROVIDER.WHATSAPP]: '/channels/whatsapp.svg',
  [PROVIDER.THREADS]: '/channels/threads.svg',
  // The `facebook` *channel* (Page comments) rides the messenger provider but
  // gets its own brand glyph for the comment surface.
  [META_CHANNEL.FACEBOOK]: '/channels/facebook.svg',
};

export const providerIcon = (type) => PROVIDER_ICON[type] || '/channels/imap.svg';

// Identity icon for an account, used by empty states (and other chrome that wants
// a single representative glyph). An external channel shows its brand icon; an MX
// domain (provider_type 'inbox2') shows its own identity — a custom uploaded icon
// or, failing that, an initials monogram — rather than the generic app cube. No
// account (e.g. the cross-domain unified inbox) → the app cube ('/logo-mark.png').
export function accountIconSrc(account) {
  if (!account) return '/logo-mark.png';
  if (account.provider_type === PROVIDER.INBOX2) {
    if (account.icon_url) return account.icon_url;
    const name = account.display_name || account.email_address;
    return name ? initialsDataUri(name) : '/logo-mark.png';
  }
  return providerIcon(account.provider_type);
}

// Friendly label for an external account (tabs, switchers). Mail accounts read
// best as their address; Meta channels store a "whatsapp:<id>" / "messenger:<id>"
// identifier in email_address, so prefer the account's display name (falling back
// to the identifier with the "<channel>:" prefix stripped).
export const channelLabel = (acct) => {
  if (!acct) return '';
  const id = acct.email_address || '';
  if (META_PROVIDERS.includes(acct.provider_type)) {
    return acct.display_name || id.replace(/^[a-z]+:/, '');
  }
  // Domain (inbox2) workspaces read best as the org's display name — which is
  // user-editable in the admin console — not the bare DNS in email_address.
  if (acct.provider_type === PROVIDER.INBOX2) {
    return acct.display_name || id;
  }
  return id || acct.display_name || '';
};

// Friendly display label for a Meta surface (used by the comment card / chat
// header), e.g. "Instagram", "Facebook". Falls back to the raw key capitalised.
export const CHANNEL_LABELS = {
  [META_CHANNEL.INSTAGRAM]: 'Instagram',
  [META_CHANNEL.MESSENGER]: 'Messenger',
  [META_CHANNEL.FACEBOOK]: 'Facebook',
  [META_CHANNEL.WHATSAPP]: 'WhatsApp',
  [META_CHANNEL.THREADS]: 'Threads',
};

// Per-platform brand theming for the social chat thread, comment card, and
// platform-style list rows. Keyed by the *channel surface* (a Messenger Page
// account carries both `messenger` DMs and `facebook` comments, so `channel` ≠
// provider type). `accent` is the outbound-bubble / highlight colour; `tint` is
// a translucent wash for headers/comment cards; `radius` shapes the bubbles;
// `wallpaper` is an optional thread background. Consumed only via CSS custom
// properties (no inline styles) — see brandVars().
export const CHANNEL_BRAND = {
  [META_CHANNEL.INSTAGRAM]: {
    accent: '#E1306C', tint: 'rgba(225, 48, 108, 0.10)', radius: '18px',
    logo: '/channels/instagram.svg', label: 'Instagram', wallpaper: null,
  },
  [META_CHANNEL.MESSENGER]: {
    accent: '#0084FF', tint: 'rgba(0, 132, 255, 0.10)', radius: '18px',
    logo: '/channels/messenger.svg', label: 'Messenger', wallpaper: null,
  },
  [META_CHANNEL.FACEBOOK]: {
    accent: '#1877F2', tint: 'rgba(24, 119, 242, 0.10)', radius: '18px',
    logo: '/channels/facebook.svg', label: 'Facebook', wallpaper: null,
  },
  [META_CHANNEL.WHATSAPP]: {
    accent: '#25D366', tint: 'rgba(37, 211, 102, 0.10)', radius: '8px',
    logo: '/channels/whatsapp.svg', label: 'WhatsApp', wallpaper: '/channels/whatsapp-bg.svg',
  },
  [META_CHANNEL.THREADS]: {
    accent: '#8A2BE2', tint: 'rgba(138, 43, 226, 0.10)', radius: '18px',
    logo: '/channels/threads.svg', label: 'Threads', wallpaper: null,
  },
};

// Neutral fallback so an unknown/missing surface still themes cleanly off the
// app accent token rather than a broken colour. The accent here resolves at
// paint time from the theme (set as a literal so brandVars stays inline-free).
export const NEUTRAL_BRAND = {
  accent: '#5b7fff', tint: 'rgba(91, 127, 255, 0.10)', radius: '14px',
  logo: '/channels/imap.svg', label: 'Channel', wallpaper: null,
};

// Resolve the brand for a conversation: prefer the channel surface, fall back to
// the provider type, then neutral. Accepts the normalized conversation shape
// ({ channel, providerType }).
export function brandFor(conv) {
  const key = conv?.channel || conv?.providerType;
  return CHANNEL_BRAND[key] || NEUTRAL_BRAND;
}

// Map a brand to the CSS custom properties the chat/comment/row CSS Modules
// read. The caller applies these onto a wrapper ref via style.setProperty so no
// inline styles are emitted (ESLint bans style={{}}). Returns [name, value]
// pairs; `--brand-wallpaper` is omitted when there's no wallpaper.
export function brandVars(brand) {
  const b = brand || NEUTRAL_BRAND;
  const pairs = [
    ['--brand-accent', b.accent],
    ['--brand-tint', b.tint],
    ['--brand-radius', b.radius],
  ];
  if (b.wallpaper) pairs.push(['--brand-wallpaper', `url(${b.wallpaper})`]);
  return pairs;
}
