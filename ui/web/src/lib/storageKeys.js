// Centralized localStorage key constants — avoids stringly-typed duplication.
export const ACTIVE_ACCOUNT_KEY = 'inbox2_active_account';
// Last From address sent from / calendar created on (lib/lastUsedPref.js).
export const LAST_FROM_ADDRESS = 'inbox2_last_from_address';
export const LAST_EVENT_CALENDAR = 'inbox2_last_event_calendar';
// The open conversation, mirrored to storage like the active account so a desktop
// refresh (which reloads to '/' and rebuilds the route from storage, not the URL)
// can reopen it. Web keeps its real URL, so there the URL's ?c= wins.
export const ACTIVE_CONVERSATION_KEY = 'inbox2_active_conversation';
export const UNIFIED_VIEW_MODE = 'inbox2_unified_view_mode';
// Unread-only filter (⌘U) — remembered like the view mode, so leaving the
// unified inbox and coming back doesn't silently drop it.
export const UNIFIED_UNREAD_ONLY = 'inbox2_unified_unread_only';
// Unified list mode: each MX column's address folder + extra folder columns.
export const UNIFIED_COLUMN_FOLDERS = 'inbox2_unified_column_folders';
// Sidebar address-folder tree: which of Inbox / Yours / Shared are collapsed.
export const ADDRESS_TREE_COLLAPSED = 'inbox2_address_tree_collapsed';
export const MARK_READ_MODE = 'inbox2_mark_read_mode';
export const MARK_READ_DELAY = 'inbox2_mark_read_delay';
// Apollo API key moved to the encrypted secret store (lib/secretStore.js) — keyed
// by `inbox2_apollo_api_key` only as the web localStorage fallback.
export const INBOX_SORT_ORDER = 'inbox2_sort';
export const NOTIFICATIONS_ENABLED = 'inbox2_notifications_enabled';
export const NOTIFICATION_MODE = 'inbox2_notification_mode';
// Sounds panel: master enable + per-event sound choice (ids from lib/soundCatalog).
export const SOUNDS_ENABLED = 'inbox2_sounds_enabled';
export const SOUND_RECEIVE = 'inbox2_sound_receive';
export const SOUND_SEND = 'inbox2_sound_send';
export const CLOUD_PUSH_ENABLED = 'inbox2_cloud_push_enabled';
export const IMAGE_PROXY_ENABLED = 'inbox2_image_proxy_enabled';
export const SAFE_SENDERS = 'inbox2_safe_senders';
export const SHOWN_MESSAGES = 'inbox2_shown_messages';
export const ALWAYS_SHOW_IMAGES = 'inbox2_always_show_images';
export const DROPBLOCK_ENABLED = 'inbox2_dropblock_enabled';
// Opt-in "rainbow tabs" — tint each chrome workspace tab with a Catppuccin
// palette colour by position (Settings › Theme › Advanced). Off by default.
export const RAINBOW_TABS_ENABLED = 'inbox2_rainbow_tabs';
export const DROPBLOCK_STATE = 'inbox2_dropblock_state';
// Map of context-sidebar panel key → collapsed boolean (JSON object).
export const COLLAPSED_PANELS = 'inbox2_collapsed_panels';
export const THEME = 'inbox2_theme';
// Per-theme user token overrides (advanced customizer): { [themeId]: { '--token': value } }.
export const THEME_OVERRIDES = 'inbox2_theme_overrides';
// Per-theme background choice: { [themeId]: { mode: 'default'|'custom', image?: dataURL } }.
export const THEME_BACKGROUNDS = 'inbox2_theme_backgrounds';
// UI text size multiplier applied to <html> font-size (all --text-* are rem).
export const TEXT_SCALE = 'inbox2_text_scale';
export const SYNC_FOLDERS = 'inbox2_sync_folders';
export const DEV_MODE = 'inbox2_dev_mode';
export const APOLLO_CACHE = 'inbox2_apollo_cache';
export const DROPBLOCK_MUTED = 'inbox2_dropblock_muted';
export const NLU_LANE = 'inbox2_nlu_lane';
export const NLU_FREE_MODEL = 'inbox2_nlu_free_model';
export const AI_MODELS = 'inbox2_ai_models';
export const AI_CONSENT = 'inbox2_ai_consent';
export const AI_ONBOARDING_DISMISSED = 'inbox2_ai_onboarding_dismissed';
// Drag & drop order of account tabs (MX domain ids + external acc_ keys), JSON array.
export const ACCOUNT_ORDER = 'inbox2_account_order';
// Last successful GET /account payload (user + orgs), hydrated synchronously at
// boot so the app paints without waiting a network RTT; restore() revalidates.
export const CACHED_ACCOUNT = 'inbox2_cached_account';
// Unified-inbox list view pane modes (pinned/floating/hidden — see usePaneMode).
export const CALENDAR_RAIL_MODE = 'inbox2_calendar_rail_mode';
// { calendarId: pastel } as assigned by the full calendar (lib/calendarColors).
export const CALENDAR_PASTELS = 'inbox2_calendar_pastels';
export const PREVIEW_PANE_MODE = 'inbox2_preview_pane_mode';
// Lore side panel in the unified inbox: pinned / floating / hidden (usePaneMode).
export const LORE_PANE_MODE = 'inbox2_lore_pane_mode';
// Touch Strip (the app-wide bottom bar): its pane mode (per device, like the
// other panes) and a local copy of its layout (synced to the account when signed in).
export const TOUCH_STRIP_MODE = 'inbox2_touch_strip_mode';
export const TOUCH_STRIP_CONFIG = 'inbox2_touch_strip_config';
// Composer: show the email-preview pane (off by default — the popup is narrower
// without it). Sizes are remembered per mode: COMPOSE_SIZE + '_nopreview'.
export const COMPOSE_PREVIEW = 'inbox2_compose_preview';
// Event editor: show the invite-email preview pane (off by default, like the composer).
export const EVENT_PREVIEW = 'inbox2_event_preview';
// Timezone planner: the zone rows the user last had open (JSON array of IANA ids).
export const TZ_PLANNER_ZONES = 'inbox2_tz_planner_zones';
// Timezone planner: per-zone display names the user typed over the city name.
export const TZ_PLANNER_LABELS = 'inbox2_tz_planner_labels';
// Calendar zones (docs/Calendar.md "Zones"): zone ids whose start card was
// dismissed ({ id: endMs }), and the categories hidden in the calendar.
export const ZONE_DISMISSED = 'inbox2_zone_dismissed';
export const ZONE_HIDDEN_CATEGORIES = 'inbox2_zone_hidden_categories';
// Disk list or grid view (FilterBar's toggle), remembered per browser.
export const DISK_VIEW_MODE = 'inbox2_disk_view_mode';
// Disk grid tile width in px (FilterBar's size slider), remembered per browser.
export const DISK_TILE_SIZE = 'inbox2_disk_tile_size';
// The org Disk is on when the person belongs to several (pages/disk/DiskLayout.jsx).
export const DISK_ORG = 'inbox2_disk_org';
// Disk: the sealing lost-keys warning was acknowledged in this browser (spec F7).
export const DISK_SEAL_ACK = 'inbox2_disk_seal_ack';
// Local WhatsApp (desktop): read WhatsApp Desktop's own database on this Mac (lib/localWhatsApp.js).
export const LOCAL_WHATSAPP_ENABLED = 'inbox2_local_whatsapp';
// Local WhatsApp: the chats open as columns on this device (pages/whatsapp/WhatsAppPage.jsx).
export const WA_OPEN_COLUMNS = 'inbox2_wa_open_columns';
