# spec 10.2 — Email notifications for events with per-event toggles
class EmailNotifier
  def self.notify(user:, event:, conversation:, actor: nil)
    return unless Notification::KINDS.include?(event)
    # TODO: check user's notification preferences before sending

    notification = Notification.create!(
      user: user,
      organization: conversation.organization,
      conversation: conversation,
      kind: event,
      title: title_for(event, actor),
      body: "Conversation: #{conversation.subject}",
      actor_membership_id: actor&.id
    )

    # TODO: queue actual email delivery via ActionMailer
    Rails.logger.info("[EmailNotifier] #{event} notification created for #{user.username}: #{notification.key}")
    notification
  end

  def self.title_for(event, actor)
    actor_name = actor&.user&.display_name || actor&.user&.username || "Someone"
    case event
    when Notification::KIND_ASSIGNMENT then "#{actor_name} assigned you to a conversation"
    when Notification::KIND_MENTION then "#{actor_name} mentioned you in a note"
    when Notification::KIND_ACCESS_GRANT then "#{actor_name} gave you access to a conversation"
    when Notification::KIND_REPLY then "#{actor_name} replied to a conversation"
    else "New notification"
    end
  end
end
