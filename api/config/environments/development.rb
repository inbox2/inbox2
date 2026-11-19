require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.server_timing = true

  if Rails.root.join("tmp/caching-dev.txt").exist?
    config.action_controller.perform_caching = true
    config.action_controller.enable_fragment_cache_logging = true
    config.public_file_server.headers = { "cache-control" => "public, max-age=#{2.days.to_i}" }
  else
    config.action_controller.perform_caching = false
  end

  config.cache_store = :memory_store
  config.active_support.deprecation = :log
  config.active_record.migration_error = :page_load
  config.active_record.verbose_query_logs = true
  config.active_record.query_log_tags_enabled = true
  config.active_job.verbose_enqueue_logs = true

  # Action Cable — allow from React dev server
  config.action_cable.disable_request_forgery_protection = true

  # Cloud push (dev): allow inbound provider webhooks via the public tunnel.
  # Cloudflare quick-tunnel hostnames rotate per session, so allow the whole
  # *.trycloudflare.com space (dev only). See docs/Cloud-Push.md.
  config.hosts << "push-dev.inbox2.com"      # named Cloudflare tunnel (stable)
  config.hosts << /.*\.trycloudflare\.com/   # Cloudflare quick tunnel (ephemeral)
  config.hosts << /.*\.ts\.net/              # Tailscale Funnel, if used later
end
