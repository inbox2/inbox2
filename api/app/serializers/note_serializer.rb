class NoteSerializer < ::ApplicationSerializer
  attributes :body, :created_at

  attribute :parent_note_id do |note|
    note.parent_note&.key
  end

  # Uses the preloaded :reactions (with :membership) and :replies associations
  # from ConversationsController#show — `.size`/group_by over the loaded
  # collections, no per-note query.
  attribute :reactions do |note|
    note.reactions.group_by(&:emoji).map do |emoji, group|
      { emoji: emoji, count: group.size, members: group.map { |r| r.membership.key } }
    end
  end

  attribute :reply_count do |note|
    note.replies.size
  end

  one :membership, serializer: MembershipSerializer, key: :author
end
