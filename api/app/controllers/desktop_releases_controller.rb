# Desktop app distribution (bundles in the Pushleft bucket, see DesktopReleases).
#
# Three public, unauthenticated endpoints:
#   - manifest: the Tauri updater latest.json. The running app polls it, so it
#     can't carry a session. Served with a SHORT cache (updates must not appear
#     delayed) — unlike the 1-year static cache on /public binaries. Raw Tauri
#     JSON contract, a deliberate E2/Alba exception (cf. WellKnownController).
#   - latest: the /console download card data, via DesktopReleaseSerializer.
class DesktopReleasesController < ApplicationController
  # GET /downloads/desktop/latest.json
  def manifest
    version = DesktopReleases.latest_version
    json = version && DesktopReleases.manifest_json(version)
    return head :not_found if json.nil?

    # Short TTL so a freshly-published build is picked up within a minute.
    expires_in 60.seconds, public: true
    # `json` is already a JSON string — render verbatim (render json: would
    # re-encode the string, wrapping it in quotes).
    render body: json, content_type: "application/json"
  end

  # GET /downloads/desktop/:version/:file — the URLs in every manifest and on
  # the console. Versioned files never change, so the redirect may be cached for
  # a while, but not past the 15-minute signature.
  def file
    url = DesktopReleases.download_url(params[:version], params[:file])
    return head :not_found if url.nil?

    expires_in 5.minutes, public: true
    redirect_to url, allow_other_host: true
  end

  # GET /api/v1/desktop/releases/latest
  def latest
    release = DesktopReleases.latest
    return head :no_content if release.nil?

    expires_in 60.seconds, public: true
    render json: DesktopReleaseSerializer.new(release).serialize
  end
end
