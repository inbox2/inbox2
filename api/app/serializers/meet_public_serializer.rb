# The visitor-facing meet-link payload (docs/Calendar.md). Deliberately NOT
# MeetLinkSerializer: no token echo, no stats, no creator — only what the
# public page renders. No `id` either: the URL token is the visitor's only
# handle, and the mtl_ key stays internal to owners.
#
# params: availability (MeetAvailability), avatar_url, site_key.
class MeetPublicSerializer
  include Alba::Resource

  attributes :label, :duration_minutes, :min_notice_minutes, :max_ahead_days

  attribute :timezone do
    params[:availability].timezone
  end

  attribute :working_hours do
    params[:availability].working_hours
  end

  attribute :invitee do |link|
    {
      name: link.invitee_membership.user&.then { |u| u.display_name.presence || u.username },
      avatar_url: params[:avatar_url]
    }
  end

  attribute :organization do |link|
    link.organization.name
  end

  attribute :turnstile_site_key do
    params[:site_key]
  end
end
