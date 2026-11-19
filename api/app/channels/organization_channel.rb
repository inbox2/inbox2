# Per-organization stream for live mail signals to web clients. New MX mail lands
# in the org pool (InboundMailProcessor) and is fanned out to "organization_<key>";
# subscribed web clients refresh their unified/domain inbox lists in real time
# instead of waiting on the 30s polling failsafe.
#
# Auth: the socket's current_user (resolved by ApplicationCable::Connection from
# the session cookie / bearer) must be an ACTIVE member of the org named by `key`.
# accessible_organizations already scopes to active memberships, so a non-member —
# or an unknown key — resolves to nil and the subscription is rejected (E3 tenant
# isolation). See docs/MX-Inbound.md and inbound_mail_processor.rb for the broadcast.
class OrganizationChannel < ApplicationCable::Channel
  def subscribed
    org = current_user.accessible_organizations.find_by(key: params[:key])
    return reject unless org

    stream_from "organization_#{org.key}"
  end
end
