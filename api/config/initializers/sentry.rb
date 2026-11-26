# Errors and request timings to Pushleft's Errors page, through the Sentry SDK.
# Off without SENTRY_DSN (development, tests). The release is the deployed commit:
# deploy/pushleft/run exports SENTRY_RELEASE from the REVISION file CI writes.
#
# Mail content and addresses stay out of reports. With send_default_pii off,
# sentry-ruby 7 collects no request bodies (a message's raw_b64 never goes), no
# query strings, cookies, user info, SQL data or queue payloads
# (Sentry::DataCollection.backfill), and sentry-rails sends no logs
# (structured_logging is off). Do not set config.data_collection: that replaces
# the backfill with the SDK's collect-everything defaults.
module SentryScrub
  # Tokens and ids in paths (/l/:token, /disk/links/:token, /meet/:token, …):
  # any segment of 16 or more URL-safe characters.
  SEGMENT = %r{/[A-Za-z0-9_-]{16,}(?=[/.]|\z)}

  def self.call(event, _hint)
    event.request.url = event.request.url.gsub(SEGMENT, "/:token") if event.request&.url
    event
  end
end

if ENV["SENTRY_DSN"].present?
  Sentry.init do |config|
    config.traces_sample_rate = 0.1
    config.send_default_pii = false
    config.before_send = SentryScrub.method(:call)
    config.before_send_transaction = SentryScrub.method(:call)
  end
end
