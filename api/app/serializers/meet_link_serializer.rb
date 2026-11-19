# Owner-facing meet link (docs/Calendar.md). The public page never sees this —
# MeetController builds its own narrower payload.
class MeetLinkSerializer < ::ApplicationSerializer
  attributes :label, :token, :duration_minutes, :min_notice_minutes, :max_ahead_days,
             :conference_mode, :visits_count, :requests_count, :created_at, :revoked_at

  attribute :active do |link|
    link.active?
  end

  attribute :invitee do |link|
    membership = link.invitee_membership
    {
      id: membership.key,
      name: membership.user&.display_name,
      self: membership.id == link.membership_id
    }
  end
end
