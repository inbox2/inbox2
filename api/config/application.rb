require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Api
  class Application < Rails::Application
    config.load_defaults 8.1

    config.autoload_lib(ignore: %w[assets tasks])

    # Standard Rails (not API-only) for Action Cable. JSON-only by policy (spec 16.1.3).
    # We do NOT set api_only = true so Action Cable works.

    # Don't generate system test files
    config.generators.system_tests = nil

    # Use RSpec
    config.generators do |g|
      g.test_framework :rspec
      g.fixture_replacement :factory_bot, dir: "spec/factories"
    end

    # CORS for React frontend.
    #
    # FRONTEND_URL may be a comma-separated list. The desktop bundle is always
    # allowed: its webview runs on a custom scheme of its own (tauri://localhost
    # on macOS, http(s)://tauri.localhost on Windows/Linux), so every call it
    # makes to the API is cross-origin. It authenticates with a Bearer token from
    # the engine's encrypted store, not the session cookie.
    desktop_origins = %w[tauri://localhost http://tauri.localhost https://tauri.localhost]
    web_origins = ENV.fetch("FRONTEND_URL", "http://localhost:4173").split(",").map(&:strip).reject(&:empty?)

    config.middleware.insert_before 0, Rack::Cors do
      allow do
        origins(*web_origins, *desktop_origins)
        resource "*",
          headers: :any,
          methods: %i[get post put patch delete options head],
          credentials: true,
          expose: %w[X-Request-Id]
      end

      # Desktop release info is public, unauthenticated and read-only: the
      # marketing site (a different origin from the web app) reads it to show
      # the current version and link the real installers. No credentials.
      allow do
        origins "*"
        resource "/api/v1/desktop/releases/latest", headers: :any, methods: %i[get options head]
        resource "/downloads/desktop/latest.json", headers: :any, methods: %i[get options head]
      end
    end
  end
end
