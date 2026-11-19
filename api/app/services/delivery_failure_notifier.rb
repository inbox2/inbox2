# spec 20.2.5 / TODO 46.8 — Delivery-failure notifications. Fires once when a
# DeliveryStatus first lands on failed/bounced (the DeliveryStatus callback
# guards against re-notifying on failed→bounced upgrades) and notifies everyone
# with a stake in the thread: the sending mailbox's owner and the conversation's
# assignees.
class DeliveryFailureNotifier
  def self.call(delivery_status)
    message = delivery_status.message
    conversation = message&.conversation
    organization = message&.organization
    return unless conversation && organization

    users = recipients(message, conversation, organization)
    return if users.empty?

    bounced = delivery_status.status == DeliveryStatus::STATUS_BOUNCED
    title = "#{bounced ? 'Message bounced' : 'Delivery failed'}: #{conversation.subject.presence || 'your message'}"
    # One row per destination, so say WHICH one failed — the other destinations
    # of the same message may well have gone through.
    failed_to = delivery_status.recipient_list.presence&.join(", ") || message.to_address
    body = [
      ("To: #{failed_to}" if failed_to.present?),
      delivery_status.dsn_diagnostic.presence || delivery_status.dsn_code.presence
    ].compact.join(" — ")

    users.each do |user|
      Notification.create!(
        user: user,
        organization: organization,
        conversation: conversation,
        kind: Notification::KIND_DELIVERY_FAILURE,
        title: title,
        body: body.presence || "The message could not be delivered."
      )
    end
  end

  # The sender (owner of the org mailbox the message went out from) plus the
  # conversation's assignees, deduped.
  def self.recipients(message, conversation, organization)
    users = conversation.assignees.includes(:user).map(&:user)
    if message.from_address.present?
      local, domain = message.from_address.downcase.split("@", 2)
      sender = Mailbox.joins(:domain, :membership)
        .where(local_part: local, domains: { name: domain, organization_id: organization.id })
        .first&.membership&.user
      users << sender if sender
    end
    users.compact.uniq
  end
  private_class_method :recipients
end
