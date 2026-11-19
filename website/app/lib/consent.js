/**
 * Analytics consent for the marketing site.
 *
 * Nothing is loaded and no cookie is written until someone accepts. Google
 * Analytics and PostHog are injected on acceptance and on later visits that
 * already carry it; withdrawing clears their cookies and reloads, which is the
 * only way to make a withdrawal actually take effect in the same tab.
 */

export const CONSENT_KEY = "inbox2.analytics-consent.v1";

/** The stored values. Anything else (including null) counts as "not asked yet". */
export const CONSENT = {
  ACCEPTED: "accepted",
  DECLINED: "declined",
};

const GA_ID = import.meta.env.VITE_GA_ID;
const PH_KEY = import.meta.env.VITE_POSTHOG_KEY;
const PH_HOST = import.meta.env.VITE_POSTHOG_HOST || "https://eu.i.posthog.com";

/** Cookie name prefixes the two vendors write, cleared on withdrawal. */
const VENDOR_COOKIE_PREFIXES = ["_ga", "_gid", "_gat", "ph_"];

export function readConsent() {
  if (typeof window === "undefined") return null;
  try {
    return window.localStorage.getItem(CONSENT_KEY);
  } catch {
    // Safari in private mode throws on localStorage. Treat it as never asked;
    // the banner shows again next visit and nothing is ever loaded.
    return null;
  }
}

export function writeConsent(value) {
  try {
    window.localStorage.setItem(CONSENT_KEY, value);
  } catch {
    /* nothing to do: the banner will simply ask again */
  }
}

let started = false;

/** Inject the vendor scripts. Safe to call twice. */
export function startAnalytics() {
  if (started || typeof window === "undefined") return;
  started = true;

  if (GA_ID) {
    const tag = document.createElement("script");
    tag.async = true;
    tag.src = `https://www.googletagmanager.com/gtag/js?id=${encodeURIComponent(GA_ID)}`;
    document.head.appendChild(tag);
    window.dataLayer = window.dataLayer || [];
    window.gtag = function gtag() {
      window.dataLayer.push(arguments);
    };
    window.gtag("js", new Date());
    window.gtag("config", GA_ID, { anonymize_ip: true });
  }

  if (PH_KEY) {
    const tag = document.createElement("script");
    tag.async = true;
    // ponytail: PostHog's official install is a long stub that queues calls made
    // before the bundle lands. We make none, so loading array.js and initialising
    // in onload is the whole job. Swap in the stub if we ever capture on boot.
    tag.src = `${PH_HOST}/static/array.js`;
    tag.onload = () => {
      window.posthog?.init(PH_KEY, {
        api_host: PH_HOST,
        person_profiles: "identified_only",
      });
    };
    document.head.appendChild(tag);
  }
}

/**
 * Every domain a vendor could have written the cookie on: the exact host and
 * each parent up to the registrable domain. GA writes `_ga` on the highest
 * domain it can, so on `www.example.com` the cookie is on `.example.com` and
 * deleting it at the host does nothing.
 */
function cookieDomains() {
  const parts = location.hostname.split(".");
  const out = [location.hostname];
  for (let i = 0; i < parts.length - 1; i += 1) out.push(`.${parts.slice(i).join(".")}`);
  return out;
}

function clearVendorCookies() {
  const domains = cookieDomains();
  for (const entry of document.cookie.split(";")) {
    const name = entry.split("=")[0].trim();
    if (!VENDOR_COOKIE_PREFIXES.some((p) => name.startsWith(p))) continue;
    for (const domain of domains) {
      document.cookie = `${name}=; Max-Age=0; path=/; domain=${domain}`;
    }
    document.cookie = `${name}=; Max-Age=0; path=/`;
  }
}

/** Record a choice and act on it. `reloadOnWithdraw` is for the settings link. */
export function applyConsent(value, { reloadOnWithdraw = false } = {}) {
  writeConsent(value);
  if (value === CONSENT.ACCEPTED) {
    startAnalytics();
    return;
  }
  clearVendorCookies();
  if (reloadOnWithdraw && started) window.location.reload();
}

/** True when either vendor is configured. With neither, the banner has nothing to ask about. */
export const ANALYTICS_CONFIGURED = Boolean(GA_ID || PH_KEY);
