# Offboards a user from one or more domains the acting admin manages: decides
# what happens to the departed mailbox's mail and to their old address, then
# removes the membership. Transactional across all target orgs.
#
# Per org:
#   * alias_handling — what future mail to the old local_part@domain does:
#       "reroute" → a chosen active member gains access to that mailbox going
#                   forward (a MailboxAlias reroute pointing at them).
#       "bounce"  → future mail is rejected at ingest (a MailboxAlias bounce).
#   * data_handling — the existing mailbox-addressed mail:
#       "archive" → no-op retain. The admin keeps full org-wide visibility; the
#                   departed user already loses access when the membership goes.
#       "wipe"    → delete every message addressed to/from local_part@domain,
#                   then drop any conversation left with no messages. Shared
#                   org-wide threads holding other people's mail survive — wipe
#                   is message-level, not thread-level.
class UserOffboarder
  class InvalidRerouteTarget < StandardError; end

  ARCHIVE = "archive".freeze
  WIPE = "wipe".freeze

  def initialize(user:, organizations:, acting_user:, data_handling:, alias_handling:, reroute_target_key: nil)
    @user = user
    @orgs = Array(organizations)
    @acting_user = acting_user
    @data_handling = data_handling.presence || ARCHIVE
    @alias_handling = alias_handling.presence || MailboxAlias::MODE_BOUNCE
    @reroute_target_key = reroute_target_key
  end

  def call
    ActiveRecord::Base.transaction do
      @orgs.each { |org| offboard_from(org) }
    end
  end

  private

  def offboard_from(org)
    membership = org.memberships.find_by(user: @user)
    return unless membership

    # One address per mailbox (membership × domain): retire each, and wipe its
    # mail when requested.
    membership.mailboxes.includes(:domain).each do |mailbox|
      retire_address(org, membership, mailbox)
      wipe_mailbox_mail(org, mailbox.email_address) if @data_handling == WIPE
    end

    reassign_primary_owner(org, membership)
    membership.destroy!
  end

  def retire_address(org, membership, mailbox)
    target = nil
    if @alias_handling == MailboxAlias::MODE_REROUTE
      target = org.memberships.find_by(key: @reroute_target_key, status: Membership::STATUS_ACTIVE)
      raise InvalidRerouteTarget unless target && target.id != membership.id
    end

    org.mailbox_aliases.find_or_initialize_by(domain_id: mailbox.domain_id, local_part: mailbox.local_part).update!(
      domain: mailbox.domain,
      mode: @alias_handling,
      target_membership: target
    )
  end

  # If the departing member is the org's *primary* owner, promote another active
  # owner-role membership to primary (owner_id is nullable, so nil if none left).
  def reassign_primary_owner(org, membership)
    return unless org.owner_id == membership.user_id

    successor = org.memberships
      .where(role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE)
      .where.not(id: membership.id).first
    org.update_column(:owner_id, successor&.user_id)
  end

  def wipe_mailbox_mail(org, address)
    # Resolve the matching ids once — the leading-wildcard LIKE can't use an
    # index, so run that scan a single time, then work off the id set.
    message_ids = org.messages.where(
      "LOWER(to_address) LIKE :a OR LOWER(from_address) LIKE :a OR LOWER(cc_address) LIKE :a",
      a: "%#{address.downcase}%"
    ).pluck(:id)
    return if message_ids.empty?

    conversation_ids = Message.where(id: message_ids).distinct.pluck(:conversation_id)
    # Per-record destroy so attachments/notes/etc. cascade via dependent: :destroy.
    Message.where(id: message_ids).find_each(&:destroy!)
    # Drop conversations that became empty; org-wide threads with others' mail stay.
    org.conversations.where(id: conversation_ids).where.missing(:messages).find_each(&:destroy!)
  end
end
