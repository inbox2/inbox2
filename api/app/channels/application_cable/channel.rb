module ApplicationCable
  class Channel < ActionCable::Channel::Base
    private

    # The conversation `key` as this socket's user may see it, or nil. A socket
    # spans every org the user belongs to, so the check is membership-first:
    # an active membership in the thread's org, then that membership's
    # `visible_to` slice (domain grants, personal-mailbox exclusion, private
    # imports). Same E3 rule as `visible_conversations` in the API controllers;
    # a bare `Conversation.find_by(key:)` on a channel was a cross-org window.
    def visible_conversation(key)
      conversation = Conversation.find_by(key: key)
      return nil unless conversation

      membership = current_user.memberships.active.find_by(organization_id: conversation.organization_id)
      return nil unless membership

      conversation.organization.conversations.visible_to(membership).find_by(id: conversation.id)
    end

    def visible_conversation!(key)
      visible_conversation(key) or raise ActiveRecord::RecordNotFound
    end
  end
end
