# Off-request badge fan-out: refreshing an org's app-icon badges walks every
# active membership + device, which a large org paid in-request on every single
# read/unread toggle. The controller enqueues; the walk happens here.
class MobileBadgeRefreshJob < ApplicationJob
  queue_as :default
  discard_on ActiveJob::DeserializationError

  def perform(organization_id)
    organization = Organization.find_by(id: organization_id)
    return unless organization # org deleted since enqueue

    MobilePushSender.refresh_badge_for_org(organization)
  end
end
