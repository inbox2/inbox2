# Public click-tracking redirect (no auth). A tracked outgoing mail rewrites every
# <a href> to https://<track-host>/l/<token>; each click hits here, is recorded,
# then 302s to the original URL. Never caches (so every click counts). See
# docs/Open-Tracking.md.
class LinkController < ApplicationController
  def show
    link = TrackedLink.find_by(token: params[:token].to_s)

    # Unknown token → 404 (never an open redirect; we only ever send to a URL we
    # ourselves stored at compose time).
    return head :not_found if link.nil?
    return head :not_found unless link.url.to_s.match?(%r{\Ahttps?://}i)

    begin
      LinkClick.record!(token: link.token, request: request, organization_id: link.organization_id)
    rescue => e
      Rails.logger.warn("[LinkController] failed to record click for #{link.token}: #{e.message}")
    end

    response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, private"
    redirect_to link.url, allow_other_host: true, status: :found
  end
end
