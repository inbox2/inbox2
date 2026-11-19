# Public open-tracking pixel (no auth). A tracked outgoing mail embeds
# <img src="https://<track-host>/o/<token>.gif">; each recipient render hits here.
# Always returns the 1x1 GIF (even for unknown tokens — never leak which are real)
# and never caches (so every render counts, not just the first).
class PixelController < ApplicationController
  def show
    token = params[:token].to_s

    if token.present?
      # MX correlation: a matching Message scopes the open to its org. Local-channel
      # tokens match nothing here — recorded with no org, polled back by the client.
      org_id = Message.where(tracking_token: token).limit(1).pick(:organization_id)
      begin
        MessageOpen.record!(token: token, request: request, organization_id: org_id)
      rescue => e
        Rails.logger.warn("[PixelController] failed to record open for #{token}: #{e.message}")
      end
    end

    response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, private"
    response.headers["Pragma"] = "no-cache"
    send_data Tracking::PIXEL_GIF, type: "image/gif", disposition: "inline"
  end
end
