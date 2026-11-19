# Records member-attributed ActivityEvents for the Team activity board, gated on
# the org's insights switch (`activity_tracking_enabled`). Included by the
# controllers whose actions represent trackable work (reply / read / archive /
# trash / snooze / assign).
#
# Best-effort by design: analytics must never break the user action that
# triggered it, so a logging failure is swallowed with a warning.
module RecordsActivity
  extend ActiveSupport::Concern

  private

  # Log `action` for one conversation or a set of them, attributed to the acting
  # membership. No-op when tracking is off, there's no active membership, or the
  # target set is empty.
  #
  # ponytail: one INSERT per conversation. Bulk actions here touch a page's worth
  # at most; batch via insert_all (with generated keys) if bulk sizes grow large.
  def record_activity(action, conversation: nil, conversations: nil, metadata: {})
    return unless current_organization&.activity_tracking_enabled?
    membership = current_membership
    return unless membership

    targets = Array(conversations).presence || Array(conversation)
    return if targets.empty?

    targets.each do |c|
      ActivityEvent.log(conversation: c, action: action, membership: membership, metadata: metadata)
    end
  rescue => e
    Rails.logger.warn("[RecordsActivity] #{action} failed: #{e.message}")
  end
end
