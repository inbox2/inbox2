# CSRF: skip_forgery_protection below, on purpose (see the comment there).
class ApplicationController < ActionController::Base # nosemgrep: ruby.lang.security.missing-csrf-protection
  # Stateless JSON API: auth is a bearer token (native clients) or the HttpOnly
  # session cookie (web SPA), fenced by CORS (single allowed Origin). The Rails
  # authenticity-token CSRF machinery does not apply — there are no server-rendered
  # forms — and `:null_session` actively breaks web login: on a cross-origin request
  # (browser Origin mail.inbox2.com ≠ API base_url api.inbox2.com) the request is
  # "unverified", so null_session swaps in a NullCookieJar that SILENTLY DISCARDS the
  # Set-Cookie from `set_session_cookie` → the SPA never receives its session and
  # bounces back to login on refresh. CSRF is instead defended by the cookie's
  # SameSite=Lax (never sent on cross-site POSTs) + the CORS allow-list.
  skip_forgery_protection

  # Web SPA session cookie. The browser stores the session token here (HttpOnly,
  # so XSS can't read it) instead of localStorage; native clients (desktop / CLI /
  # mobile) keep using the Authorization: Bearer header. Host-only (no Domain) so
  # it works both in dev (browser sees localhost) and prod (api.inbox2.com, which
  # is same-site as mail.inbox2.com → SameSite=Lax is sent cross-subdomain yet
  # blocks cross-site CSRF).
  SESSION_COOKIE = :inbox2_session

  rescue_from ActiveRecord::RecordNotFound, with: :not_found
  rescue_from ActiveRecord::RecordInvalid, with: :unprocessable
  rescue_from ActionController::ParameterMissing, with: :bad_request
  # A before_destroy guard said no (e.g. a member whose Disk C:\ is not reassigned yet).
  rescue_from ActiveRecord::RecordNotDestroyed, with: :not_destroyed

  private

  def not_found
    render json: ErrorSerializer.serialize("Not found", status: 404), status: :not_found
  end

  def unprocessable(exception)
    render json: ErrorSerializer.serialize(exception.record.errors.full_messages, status: 422), status: :unprocessable_content
  end

  def not_destroyed(exception)
    messages = exception.record&.errors&.full_messages.presence || [exception.message]
    render json: ErrorSerializer.serialize(messages, status: 422), status: :unprocessable_content
  end

  def bad_request(exception)
    render json: ErrorSerializer.serialize(exception.message, status: 400), status: :bad_request
  end

  def current_user
    @current_user ||= authenticate_user
  end

  def authenticate_user!
    render json: ErrorSerializer.serialize("Unauthorized", status: 401), status: :unauthorized unless current_user
  end

  def authenticate_user
    # Header first (native clients + personal ink_ API keys); fall back to the
    # HttpOnly session cookie (web SPA). Only session tokens are ever set in the
    # cookie — ink_ keys are header-only.
    token = bearer_token.presence || cookies[SESSION_COOKIE].presence
    return nil unless token

    # Web sessions first; then personal API keys (ink_…), which let standalone
    # desktop clients reach user-scoped endpoints (image proxy, push) without a
    # browser session. See ApiKey.authenticate.
    session = Session.find_by_token(token)
    if session&.active?
      session.touch(:last_active_at)
      @current_session = session
      return session.user
    end

    key = ApiKey.authenticate(token)
    return nil unless key

    @current_api_key = key
    key.user
  end

  def bearer_token
    request.headers["Authorization"]&.split(" ")&.last
  end

  # The personal API key that authenticated this request, or nil for web/session
  # auth. Used to enforce per-key scopes (see BaseController#enforce_api_key_scope!).
  attr_reader :current_api_key

  # The web/native session that authenticated this request, or nil for API keys.
  attr_reader :current_session

  def create_session_for(user)
    session = user.sessions.create!(
      ip_address: request.remote_ip,
      user_agent: request.user_agent,
      last_active_at: Time.current
    )
    # The Pushleft Admin page lists people on this, newest first.
    user.update_column(:last_sign_in_at, Time.current)
    set_session_cookie(session.raw_token)
    session
  end

  # Store the session token in the HttpOnly cookie for the web SPA. Native clients
  # ignore the Set-Cookie and use the bearer token returned in the JSON body.
  def set_session_cookie(raw_token)
    cookies[SESSION_COOKIE] = {
      value: raw_token,
      httponly: true,
      secure: request.ssl?, # https in prod; off for local http dev
      same_site: :lax,
      expires: 30.days.from_now
    }
  end

  def clear_session_cookie
    cookies.delete(SESSION_COOKIE)
  end
end
