require "spec_helper"
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
abort("Production!") if Rails.env.production?
require "rspec/rails"

Dir[Rails.root.join("spec/support/**/*.rb")].each { |f| require f }

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include FactoryBot::Syntax::Methods

  config.before(:suite) do
    DatabaseCleaner.strategy = :transaction
    DatabaseCleaner.clean_with(:truncation)
  end
end

Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end

# N+1 guard (code audit 2026-10-18, TODO 47.9): every HTTP request a request
# spec makes runs under Prosopite; a repeated per-row query raises instead of
# slipping into prod. Only the request is scanned — factory loops in setup are
# not the app's problem. Mark a spec `prosopite: false` only with a comment
# saying why the N+1 is acceptable there.
require "prosopite"
module ProsopiteRequestApp
  def app
    return ::Rails.application if RSpec.current_example&.metadata&.[](:prosopite) == false

    @prosopite_app ||= lambda do |env|
      result = nil
      Prosopite.scan { result = ::Rails.application.call(env) }
      result
    end
  end
end

RSpec.configure do |config|
  config.before(:suite) do
    Prosopite.rails_logger = true
    Prosopite.raise = true
    # A pair of identical queries is usually the personal workspace + one team
    # (Disk C:\ next to D:\); three or more is a loop.
    Prosopite.min_n_queries = 3
    # Write paths that inherently do per-row work (offboarding a member's rows,
    # Disk node operations, pushing to every device) — not list renders. Each
    # carries its own ceiling note where it matters.
    Prosopite.allow_stack_paths = %w[
      app/services/user_offboarder.rb
      app/services/disk/node_ops.rb
      app/services/disk/sealing.rb
      app/services/disk/lifecycle.rb
      app/services/mobile_push_sender.rb
      app/services/saas/dashboard_metrics.rb
      Tag.ensure_system_tags
      Space.ensure_default_spaces
      View.ensure_system_views
      Disk::Share#assign_slug
      Disk::Event.record!
    ]
  end
  config.include ProsopiteRequestApp, type: :request
end
