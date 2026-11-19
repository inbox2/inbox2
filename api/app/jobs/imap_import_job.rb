# Runs an IMAP import off the request thread (spec 11.2.1, A15.4). The import is
# network-bound and loops up to ImapImportService::MAX_MESSAGES doing per-message
# fetches + DB writes, so it must never block a web worker. The controller
# enqueues this and returns 202 immediately.
#
# Note: the IMAP password travels in the job args (and thus the queue store)
# until the job completes — acceptable for this one-shot admin-triggered import,
# but don't widen its retention.
class ImapImportJob < ApplicationJob
  queue_as :default
  discard_on ActiveJob::DeserializationError

  def perform(organization_id, config)
    organization = Organization.find_by(id: organization_id)
    return unless organization

    ImapImportService.new(organization, config.symbolize_keys).import
  end
end
