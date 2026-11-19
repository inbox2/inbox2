# A single row in a member's activity feed: the action, its metadata, when it
# happened, and the conversation it touched (public key + subject for the link).
class MemberActivityEventSerializer < ::ApplicationSerializer
  attributes :action, :metadata, :created_at

  attribute :conversation do |e|
    e.conversation && { id: e.conversation.key, subject: e.conversation.subject }
  end
end
