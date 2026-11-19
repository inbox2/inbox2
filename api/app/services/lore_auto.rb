# Lore "Handled for you" auto mode on MX (docs/Triage.md "Auto mode"): when a
# label lands that the person switched to auto, file the thread away — fyi /
# receipt → archive, notification → trash — exactly as the bulk endpoint does.
#
# Only in a domain with exactly ONE member (never on a shared team inbox), with
# that member's setting. Never on a manual label or a thread they replied in.
class LoreAuto
  ACTIONS = {
    TriageLabel::FYI => Conversation::STATUS_ARCHIVED,
    TriageLabel::RECEIPT => Conversation::STATUS_ARCHIVED,
    TriageLabel::NOTIFICATION => Conversation::STATUS_TRASH
  }.freeze

  # Returns the status it moved the thread to, or nil.
  def self.apply(conversation)
    status = ACTIONS[conversation.triage_label]
    return nil unless status && conversation.status == Conversation::STATUS_OPEN && conversation.domain
    return nil if conversation.triage_source.to_s.start_with?(TriageLabel::SOURCE_MANUAL)
    return nil if conversation.messages.where(is_inbound: false).exists? # the person replied

    member = sole_member(conversation.domain)
    return nil unless member&.user&.lore_auto_on?(conversation.triage_label)

    Conversation.update_all_in_order(Conversation.where(id: conversation.id),
                                     status: status,
                                     triage_source: "#{conversation.triage_source}#{TriageLabel::SOURCE_AUTO_SUFFIX}")
    conversation.reload
    status
  end

  # The one active human who sees this domain's pool (owners/admins and
  # all-domains members see every domain), or nil when it's shared or empty.
  def self.sole_member(domain)
    granted = MembershipDomain.where(domain_id: domain.id).select(:membership_id)
    scope = domain.organization.memberships.active.humans
    members = scope.where(role: Membership::ADMIN_ROLES).or(scope.where(all_domains: true))
                   .or(scope.where(id: granted)).limit(2).to_a
    members.one? ? members.first : nil
  end
  private_class_method :sole_member
end
