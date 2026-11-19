/**
 * Top-nav routing rules — single source of truth for the header and footer.
 *   { label, to }              internal route   → <Link to>
 *   { label, href }            outbound link    → <a href target=_blank>
 */
export const NAV_ITEMS = [
  { id: "home", label: "Home", to: "/" },
  { id: "mx", label: "MX", to: "/mx" },
  { id: "console", label: "Console", href: "https://mail.inbox2.com/console" },
  { id: "topologies", label: "Self-host", to: "/topologies" },
  { id: "download", label: "Download", to: "/download" },
  { id: "docs", label: "Docs", href: "https://github.com/inbox2/inbox2" },
];

export const LOGIN_URL = "https://mail.inbox2.com/login";
export const SIGNUP_URL = "https://mail.inbox2.com/signup";
export const CONSOLE_URL = "https://mail.inbox2.com/console";
export const WEB_APP_URL = "https://mail.inbox2.com";

export const FOOTER_COLUMNS = [
  {
    title: "The apps",
    items: [
      { label: "Desktop", to: "/#hero-tour" },
      { label: "Web", href: WEB_APP_URL },
      { label: "Mobile", to: "/#mobile" },
      { label: "Live Activities", to: "/#mobile" },
      { label: "On-device AI", to: "/#on-device-ai" },
      { label: "Download", to: "/download" },
    ],
  },
  {
    title: "inbox2 MX",
    items: [
      { label: "How MX works", to: "/mx" },
      { label: "Views", to: "/mx" },
      { label: "Routing rules", to: "/mx" },
      { label: "Sending API", to: "/mx#sending-api" },
      { label: "IMAP and SMTP", to: "/mx#mail-clients" },
      { label: "Pricing", to: "/mx#pricing" },
      { label: "Console", href: CONSOLE_URL },
    ],
  },
  {
    title: "Run it",
    items: [
      { label: "Cloud MX", to: "/topologies" },
      { label: "Self-hosted cloud", to: "/topologies" },
      { label: "On-premises", to: "/topologies" },
      { label: "Topologies", to: "/topologies" },
    ],
  },
  {
    title: "Company",
    items: [
      { label: "GitHub", href: "https://github.com/inbox2/inbox2" },
      { label: "Contact", href: "mailto:hello@inbox2.com" },
    ],
  },
];

/**
 * Bottom bar of the footer, beside the copyright line.
 * `action` renders a button instead of a link; the Footer knows the verbs.
 */
export const FOOTER_LEGAL = [
  { label: "GitHub", href: "https://github.com/inbox2/inbox2" },
  { label: "Contact", href: "mailto:hello@inbox2.com" },
  { label: "Privacy", to: "/privacy" },
  { label: "Terms", to: "/terms" },
  { label: "Cookie settings", action: "cookies" },
];

// The CLI's moving GitHub release (.github/workflows/cli-release.yml): one asset
// per platform, downloaded as <CLI_RELEASE>/inbox2-cli-<os>-<arch>.tar.gz.
export const CLI_RELEASE_PAGE = "https://github.com/inbox2/inbox2/releases/tag/cli-latest";
export const CLI_RELEASE = "https://github.com/inbox2/inbox2/releases/download/cli-latest";
