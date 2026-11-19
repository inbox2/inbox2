# Background favicon fetch for an org's default domain (enqueued on org create /
# first domain). Best-effort: a failure just leaves the org without a custom icon
# (the UI falls back to the inbox2 mark). Later domains are never fetched: they
# show their initial until an icon is uploaded.
class FetchFaviconJob < ApplicationJob
  queue_as :default
  discard_on ActiveJob::DeserializationError

  def perform(organization_id)
    org = Organization.find_by(id: organization_id)
    return unless org

    result = FaviconFetcher.new(org.default_domain&.name).call
    OrgIcon.store!(org, result) if result
  rescue StandardError => e
    Rails.logger.warn("FetchFaviconJob #{organization_id}: #{e.class}: #{e.message}")
  end
end
