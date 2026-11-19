import { useEffect, useState } from "react";

/**
 * The desktop release the auto-updater is currently serving.
 *
 * `bin/release-desktop` publishes the bundles into the api pods and Rails lists
 * the newest complete one here (public, unauthenticated, 60s cache). Reading it
 * at runtime rather than at build time keeps the site honest: a release ships
 * without a site deploy. A failure leaves `null` and every download link falls
 * back to the console page.
 */
const ENDPOINT = "https://api.inbox2.com/api/v1/desktop/releases/latest";

// One request per page load, however many components ask. The home page mounts
// both the hero button and the tile grid, which used to fetch this twice.
let pending = null;
function load() {
  pending ||= fetch(ENDPOINT)
    .then((r) => (r.ok ? r.json() : null))
    .then((data) => (data?.version ? data : null))
    .catch(() => null);
  return pending;
}

export function useLatestRelease() {
  const [release, setRelease] = useState(null);
  useEffect(() => {
    let live = true;
    // eslint-disable-next-line react-hooks/set-state-in-effect -- the release is fetched in the browser; the prerender has none.
    load().then((data) => live && data && setRelease(data));
    return () => { live = false; };
  }, []);
  return release;
}

/** Direct installer URL for one of the OS ids in PLATFORMS, or null. */
export function installerFor(release, os) {
  return release?.downloads?.find((d) => d.os === os)?.url || null;
}

export const formatSize = (bytes) => `${Math.round(bytes / 1e6)} MB`;
