class ConversationDetailSerializer < ::ApplicationSerializer
  attributes :subject, :status, :snippet, :read, :from_address, :to_address, :created_at, :updated_at
  # Jev triage + the thread's Space, so the reader's Triage menu can check the
  # current ones (same shapes as ConversationSerializer).
  attributes :triage_label, :triage_priority
  # Lore next-action fields (docs/Triage.md "Next-action fields"): null unless found.
  attributes :next_action_amount_cents, :next_action_currency, :next_action_title
  attribute(:next_action_due_on) { |conv| conv.next_action_due_on&.iso8601 }
  attribute :space do |conv|
    conv.space && { id: conv.space.key, name: conv.space.name, slug: conv.space.slug, color: conv.space.color, icon: conv.space.icon }
  end

  # The team's tags and the viewer's own private labels (Current.membership).
  many :tags, proc { |tags| tags.select { |t| t.visible_to?(Current.membership) } }, serializer: TagSerializer
  # Another member's draft is theirs alone (Message#readable_by?).
  many :messages, proc { |msgs| msgs.select { |m| m.readable_by?(Current.membership) } }, serializer: MessageSerializer
  # Collaboration state, so a client can show (not just set) who's assigned + notes.
  many :assignees, serializer: MembershipSerializer
  many :notes, serializer: NoteSerializer
end
