# Per-organization stream for live calendar signals. CalendarEventsController
# and InboundCalendarResponse broadcast to "calendar_<key>" whenever an event is
# created, changed, cancelled or answered; subscribed clients refetch the
# visible range instead of waiting on a poll.
#
# This class is what makes those broadcasts reachable — they predate it, so
# until now they were published to a stream no client could subscribe to.
#
# Auth mirrors OrganizationChannel: the socket's current_user must be an ACTIVE
# member of the org named by `key`. accessible_organizations already scopes to
# active memberships, so a non-member — or an unknown key — resolves to nil and
# the subscription is rejected (E3 tenant isolation).
class CalendarChannel < ApplicationCable::Channel
  def subscribed
    org = current_user.accessible_organizations.find_by(key: params[:key])
    return reject unless org

    stream_from "calendar_#{org.key}"
  end
end
