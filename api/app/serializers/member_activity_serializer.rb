# One member's activity summary card. `id` (= membership key) + the person's
# name/avatar, then the pre-aggregated action totals and a daily sparkline series
# built by MemberActivityController (kept out of the DB round-trip per member).
class MemberActivitySerializer < ::ApplicationSerializer
  attribute :name do |m|
    m.user&.display_name.presence || m.user&.username.presence || m.email_addresses.first || "?"
  end

  attribute :email do |m|
    m.user&.billing_email.presence || m.email_addresses.first
  end

  attribute :avatar_url do |m|
    next nil if m.user&.avatar_url.blank?

    m.user.avatar_url.start_with?("http") ? m.user.avatar_url : UserSerializer.avatar_url(m.user, org_key: params&.dig(:avatar_org_key))
  end

  attribute :totals do |_m|
    counts = params&.dig(:totals) || {}
    ActivityEvent::METRIC_ACTIONS.index_with { |a| counts[a] || 0 }
  end

  attribute :sparkline do |_m|
    daily = params&.dig(:daily) || {}
    Array(params&.dig(:dates)).map { |d| daily[d] || 0 }
  end
end
