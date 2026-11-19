module Api
  module V1
    # Instagram-Login OAuth redirect bounce. Instagram Business Login requires an
    # exact, pre-registered **HTTPS** redirect URI — it rejects the localhost
    # loopback that Google/Microsoft permit. So the desktop registers this one
    # stable URL, and we redirect the authorization `code` straight back to the
    # app's local listener (`http://localhost:<port>/oauth-callback`). The `state`
    # carries `<csrf>.<port>`; we forward only the csrf so the device can match it.
    #
    # No secrets touch this endpoint — only the short-lived auth code transits, and
    # the device exchanges it for a token locally. Unauthenticated by design
    # (inherits ApplicationController, not BaseController).
    class InstagramOauthController < ApplicationController
      LOOPBACK_PORTS = (8723..8725).freeze

      # GET /api/v1/oauth/instagram/callback?code=&state=<csrf>.<port>
      def callback
        code = params[:code].to_s
        csrf, _, port_str = params[:state].to_s.rpartition(".")
        port = port_str.to_i

        if code.blank? || csrf.blank? || !LOOPBACK_PORTS.include?(port)
          return render plain: "Invalid Instagram OAuth callback.", status: :bad_request
        end

        # Only ever bounce to a localhost loopback on one of our known ports.
        target = "http://localhost:#{port}/oauth-callback?code=#{CGI.escape(code)}&state=#{CGI.escape(csrf)}"
        redirect_to target, allow_other_host: true
      end
    end
  end
end
