# The Pushleft Admin page (docs/SaaS.md): every call comes from the Pushleft
# control plane, one address polling its open lists, and each carries a token
# signed for that one request. No throttle here applies to it.
Rack::Attack.safelist("pushleft-admin") do |req|
  req.path == "/_pushleft/admin" || req.path&.start_with?("/_pushleft/admin/")
end

Rack::Attack.throttle("auth/login", limit: 5, period: 300) do |req|
  req.ip if req.path == "/api/v1/auth/login" && req.post?
end

Rack::Attack.throttle("auth/signup", limit: 3, period: 3600) do |req|
  req.ip if req.path == "/api/v1/auth/signup" && req.post?
end

Rack::Attack.throttle("auth/password-reset", limit: 3, period: 3600) do |req|
  req.ip if req.path == "/api/v1/auth/password/reset-request" && req.post?
end

# Redeeming a reset token / an invite token / a device-link code / an SSO
# ticket: each is a guess-the-secret oracle if left open.
Rack::Attack.throttle("auth/token-redeem", limit: 10, period: 3600) do |req|
  if req.post? && %w[/api/v1/auth/password/reset /api/v1/auth/confirm-email /api/v1/members/accept-invite
                     /api/v1/auth/device-link/token /api/v1/auth/saml/exchange
                     /api/v1/auth/app-oauth/refresh].include?(req.path)
    req.ip
  end
end

# The platform operator plane (docs/SaaS.md): a handful of operators, never a
# burst — anything faster is a scan.
Rack::Attack.throttle("saas", limit: 60, period: 60) do |req|
  req.ip if req.path&.start_with?("/api/v1/saas/")
end

# Open-tracking capability poll (unauthenticated by design) and the custom
# tracking-host provisioning, which calls the Cloudflare API per request.
Rack::Attack.throttle("tracking/opens", limit: 120, period: 60) do |req|
  req.ip if req.post? && req.path == "/api/v1/tracking/opens"
end

Rack::Attack.throttle("tracking/provision", limit: 5, period: 3600) do |req|
  req.ip if req.post? && %w[/api/v1/tracking/register /api/v1/tracking/verify-host].include?(req.path)
end

Rack::Attack.throttle("auth/totp-verify", limit: 5, period: 300) do |req|
  req.ip if req.path == "/api/v1/auth/2fa/totp/verify" && req.post?
end

Rack::Attack.throttle("auth/webauthn", limit: 5, period: 300) do |req|
  req.ip if req.path&.start_with?("/api/v1/auth/webauthn/authenticate") && req.post?
end

# ── High-value / abuse-prone endpoints (per IP) ─────────────────────────────
# These are authenticated but unthrottled by default; the limits below cap
# automated abuse (credential minting, expensive scans, outbound amplification)
# without affecting normal interactive use.

# Unauthenticated OAuth token/refresh proxies — a refresh-token grinding oracle
# if left open. (The desktop relay; see oauth_proxy_controller.)
Rack::Attack.throttle("oauth/proxy", limit: 30, period: 300) do |req|
  req.ip if req.post? && req.path&.match?(%r{\A/api/v1/auth/(google|microsoft)/(token|refresh)\z})
end

# Brand lookup (docs/plans/lore.md §4b): a cache miss is an outbound homepage
# fetch. A Lore page asks for a few dozen domains at once; this caps scanning.
Rack::Attack.throttle("brands", limit: 300, period: 300) do |req|
  req.ip if req.get? && req.path&.start_with?("/api/v1/brands/")
end

# Personal API key creation.
Rack::Attack.throttle("api-keys/create", limit: 10, period: 3600) do |req|
  req.ip if req.post? && req.path == "/api/v1/account/api-keys"
end

# MCP tool execution (agent actions, incl. send).
Rack::Attack.throttle("mcp/execute", limit: 60, period: 60) do |req|
  req.ip if req.post? && req.path&.end_with?("/mcp/execute")
end

# Full-text search (expensive tsquery scans).
# Disk MCP (build guide 9c): per IP on top of each agent's own rate_limit.
Rack::Attack.throttle("disk/mcp", limit: 300, period: 60) do |req|
  req.ip if req.post? && req.path&.end_with?("/disk/mcp")
end

# Preview failure reports (spec F5): per signed-in caller, by their credential.
Rack::Attack.throttle("disk/preview-failures", limit: 30, period: 300) do |req|
  if req.post? && req.path&.end_with?("/preview-failures")
    req.get_header("HTTP_AUTHORIZATION").presence || req.cookies["inbox2_session"].presence || req.ip
  end
end

Rack::Attack.throttle("search", limit: 60, period: 60) do |req|
  req.ip if req.get? && req.path&.end_with?("/search")
end

# Image proxy — server-side outbound fetch.
Rack::Attack.throttle("image-proxy", limit: 120, period: 60) do |req|
  req.ip if req.get? && req.path == "/api/v1/image-proxy"
end

# ESP sends, per sending key (docs/ESP.md). The monthly allowance is the real
# limit; this stops a runaway loop from spending it in a minute.
Rack::Attack.throttle("esp/send", limit: 600, period: 60) do |req|
  req.env["HTTP_AUTHORIZATION"].to_s.split(" ").last.to_s[0, 12] if req.post? && req.path == "/api/v1/esp/emails"
end

# Outbound message creation/send.
Rack::Attack.throttle("messages/send", limit: 60, period: 60) do |req|
  req.ip if req.post? && req.path&.end_with?("/messages")
end

# Public webhook + unsubscribe receivers (unauthenticated).
Rack::Attack.throttle("public/webhooks", limit: 300, period: 60) do |req|
  req.ip if req.post? && req.path&.match?(%r{\A/api/v1/(push/|unsubscribe/)})
end

# Public meet-link scheduler (unauthenticated): reads are cheap but scannable,
# request creation mints inbox messages + mails — keep both tight per IP.
Rack::Attack.throttle("meet/read", limit: 120, period: 60) do |req|
  req.ip if req.get? && req.path&.start_with?("/api/v1/meet/")
end

Rack::Attack.throttle("meet/request", limit: 10, period: 3600) do |req|
  req.ip if req.post? && req.path&.match?(%r{\A/api/v1/meet/[^/]+/requests\z})
end

# Touch Strip feeds (public, unauthenticated): every upstream is cached, but the
# news feed fetches user-chosen URLs, so cap it harder than the rest.
Rack::Attack.throttle("strip/feeds", limit: 120, period: 60) do |req|
  req.ip if req.get? && req.path&.start_with?("/api/v1/strip/")
end

Rack::Attack.throttle("strip/news", limit: 20, period: 60) do |req|
  req.ip if req.get? && req.path == "/api/v1/strip/news"
end

# Disk public links (unauthenticated). Reads per IP; password tries per IP and
# per link, so many addresses cannot pool their guesses against one link.
DISK_LINK_UNLOCK = %r{\A/api/v1/disk/links/[^/]+/unlock\z}

Rack::Attack.throttle("disk-links/read", limit: 120, period: 60) do |req|
  req.ip if req.get? && req.path&.start_with?("/api/v1/disk/links/")
end

Rack::Attack.throttle("disk-links/unlock", limit: 10, period: 300) do |req|
  req.ip if req.post? && req.path&.match?(DISK_LINK_UNLOCK)
end

Rack::Attack.throttle("disk-links/unlock-per-link", limit: 30, period: 3600) do |req|
  req.path if req.post? && req.path&.match?(DISK_LINK_UNLOCK)
end

Rack::Attack.throttled_responder = lambda do |_req|
  [429, { "Content-Type" => "application/json" }, [{ errors: [{ message: "Too many requests. Try again later.", status: 429 }] }.to_json]]
end
