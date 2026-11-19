import { getSecret } from './secretStore';
import { APOLLO_CACHE as CACHE_KEY } from './storageKeys';
import { isTauri } from './tauri';
import log from './log';

// In the desktop app, route the request through the Tauri HTTP plugin so it's
// made from Rust and isn't subject to the webview's CORS policy (Apollo's API
// sends no Access-Control-Allow-Origin, so a plain browser fetch is blocked).
// On the web, fall back to the browser fetch (needs a server-side proxy to work).
async function apolloFetch(url, init) {
  if (isTauri()) {
    const { fetch: tauriFetch } = await import('@tauri-apps/plugin-http');
    return tauriFetch(url, init);
  }
  return fetch(url, init);
}

const CACHE_TTL = 7 * 24 * 60 * 60 * 1000; // 7 days

// Error thrown for hard failures (auth, rate-limit, network/CORS) so the UI can
// distinguish a real "no match in Apollo" (returns null, cached) from "the
// request never succeeded" (thrown, not cached).
export class ApolloError extends Error {
  constructor(message, kind) {
    super(message);
    this.name = 'ApolloError';
    this.kind = kind; // 'no_key' | 'http' | 'network'
  }
}

function getCache() {
  try {
    return JSON.parse(localStorage.getItem(CACHE_KEY) || '{}');
  } catch {
    return {};
  }
}

function setCache(cache) {
  // Prune entries older than TTL
  const now = Date.now();
  const pruned = {};
  for (const [key, entry] of Object.entries(cache)) {
    if (now - entry.ts < CACHE_TTL) pruned[key] = entry;
  }
  localStorage.setItem(CACHE_KEY, JSON.stringify(pruned));
}

/** Whether an Apollo API key has been configured (no network call). */
export async function isApolloConfigured() {
  return !!(await getSecret('apollo_api_key'));
}

/**
 * Read a previously-enriched contact from the local cache only — never hits the
 * network, so it never consumes an Apollo credit. Use this to render what we
 * already know for free; call enrichContact() (e.g. behind a button) to spend a
 * credit fetching the rest.
 * Returns { hit, data }: hit=false means we've never looked this email up;
 * hit=true with data=null means a cached "no match" result.
 */
export function getCachedContact(email) {
  if (!email) return { hit: false, data: null };
  const normalized = email.toLowerCase().trim();
  const cache = getCache();
  const cached = cache[normalized];
  if (cached && Date.now() - cached.ts < CACHE_TTL) {
    return { hit: true, data: cached.data };
  }
  return { hit: false, data: null };
}

/**
 * Enrich a contact by email via Apollo People API.
 * Returns { name, title, headline, linkedin_url, photo_url, company, company_domain } or null.
 */
export async function enrichContact(email) {
  if (!email) return null;

  const apiKey = await getSecret('apollo_api_key');
  if (!apiKey) {
    log.warn('Apollo', 'enrich skipped — no API key configured');
    throw new ApolloError('Add an Apollo API key first', 'no_key');
  }

  const normalized = email.toLowerCase().trim();
  const cache = getCache();
  const cached = cache[normalized];
  if (cached && Date.now() - cached.ts < CACHE_TTL) {
    log.debug('Apollo', `cache hit ${normalized} (${cached.data ? 'matched' : 'no match'})`);
    return cached.data;
  }

  log.info('Apollo', `people/match request ${normalized} (${isTauri() ? 'native http' : 'browser fetch'})`);

  let res;
  try {
    res = await apolloFetch('https://api.apollo.io/api/v1/people/match', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Cache-Control': 'no-cache',
        'X-Api-Key': apiKey,
      },
      body: JSON.stringify({ email: normalized }),
    });
  } catch (err) {
    // A browser fetch to api.apollo.io that throws here is almost always CORS
    // (Apollo doesn't send Access-Control-Allow-Origin) or an offline network.
    log.error('Apollo', `request failed for ${normalized} — likely CORS/network: ${err.message}`);
    throw new ApolloError(`Request failed (CORS/network): ${err.message}`, 'network');
  }

  if (!res.ok) {
    let body = '';
    try { body = await res.text(); } catch { /* ignore */ }
    log.error('Apollo', `HTTP ${res.status} for ${normalized}: ${body.slice(0, 300)}`);
    throw new ApolloError(`HTTP ${res.status}${res.status === 401 || res.status === 403 ? ' (check API key)' : res.status === 429 ? ' (rate limited / out of credits)' : ''}`, 'http');
  }

  const json = await res.json();
  const person = json.person;
  if (!person) {
    log.info('Apollo', `no match for ${normalized} (matched_count=${json.total_count ?? json.matched_count ?? 0})`);
    // Cache the miss so we don't spend another credit re-checking for a week.
    cache[normalized] = { ts: Date.now(), data: null };
    setCache(cache);
    return null;
  }

  const data = {
    name: person.name || null,
    first_name: person.first_name || null,
    last_name: person.last_name || null,
    title: person.title || null,
    headline: person.headline || null,
    linkedin_url: person.linkedin_url || null,
    photo_url: person.photo_url || null,
    city: person.city || null,
    state: person.state || null,
    country: person.country || null,
    company: person.organization?.name || null,
    company_domain: person.organization?.website_url || null,
  };

  log.info('Apollo', `matched ${normalized} → ${data.name || '(no name)'}${data.company ? ' @ ' + data.company : ''}${data.photo_url ? ' [has photo]' : ''}`);
  cache[normalized] = { ts: Date.now(), data };
  setCache(cache);
  return data;
}
