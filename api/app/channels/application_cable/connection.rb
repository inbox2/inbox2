module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_verified_user
    end

    private

    def find_verified_user
      # Web SPA authenticates the socket via the HttpOnly session cookie (sent on
      # the same-site WS handshake) — no token in the URL. Desktop/CLI clients have
      # no cookie, so they still pass their bearer as a query param.
      token = request.params[:token].presence ||
        request.cookies[ApplicationController::SESSION_COOKIE.to_s]
      session = Session.find_by_token(token)
      return session.user if session&.active?

      # Fall back to a personal API key (ink_…), so standalone desktop clients
      # authenticated by key (not a browser session) can reach user-scoped
      # streams like PushSyncChannel. Mirrors ApplicationController#authenticate_user.
      ApiKey.authenticate(token)&.user || reject_unauthorized_connection
    end
  end
end
