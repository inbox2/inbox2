class ConversationSerializer < ::ApplicationSerializer
  # `ai_summary_short` is the generated one-line preview (null until the
  # classifier has run, or when AI triage is off for the org) — clients fall back
  # to `snippet`, so it is safe for it to be absent.
  attributes :subject, :status, :snippet, :ai_summary_short, :read, :from_address, :to_address,
             :created_at, :updated_at

  # Jev triage (docs/Triage.md): an action-label slug (built-in or org custom;
  # see /triage-labels) and a 0.0–4.0 urgency score. Null until triaged.
  attributes :triage_label, :triage_priority
  # The local mirrors read this from the payload to keep the Inbox the same as the API's.
  attributes :sent_only
  # Lore next-action fields (docs/Triage.md "Next-action fields"): null unless found.
  attributes :next_action_amount_cents, :next_action_currency, :next_action_title
  attribute(:next_action_due_on) { |conv| conv.next_action_due_on&.iso8601 }

  # Paperclip on the row. The index action precomputes the whole page's set in one
  # query and passes it as `with_attachments`; anywhere else (a single thread
  # re-rendered after an update) falls back to an EXISTS for that one row, so the
  # flag is never silently wrong just because a caller didn't know to preload.
  attribute :has_attachment do |conv|
    set = params&.dig(:with_attachments)
    set ? set.include?(conv.id) : conv.messages.joins(:attachments).exists?
  end

  # Backed by the messages_count counter cache — avoids a per-row COUNT(*) on the
  # conversation list (the highest-traffic endpoint).
  attribute :message_count do |conv|
    conv.messages_count
  end

  # The Space (classification bucket) this thread was triaged into, or null for
  # untriaged / non-MX mail. A compact reference — the full Space (with stats and
  # members) comes from the /spaces index. Relies on includes(:space) to avoid N+1.
  attribute :space do |conv|
    next nil unless conv.space
    {
      id: conv.space.key,
      name: conv.space.name,
      slug: conv.space.slug,
      color: conv.space.color,
      icon: conv.space.icon
    }
  end

  # Who the thread is assigned to, compact (the Spaces board's Team view shows
  # their avatars). The index preloads `assignees: :user`; single-row renders
  # load it on demand. The full memberships come with the detail serializer.
  attribute :assignees do |conv|
    conv.assignees.map { |m| { id: m.key, name: m.user.display_name.presence || m.user.username } }
  end

  # Lore: did the viewer tick this personal-bucket thread off (LoreMemberDone)? Per
  # viewer, like the private labels below: the row's change bumps the thread and each
  # member's mirror re-reads its own value (docs/MX-Sync.md).
  attribute :lore_done do |conv|
    member = Current.membership
    !member.nil? && conv.lore_member_dones.any? { |d| d.membership_id == member.id }
  end

  # The team's tags and the viewer's own private labels (Current.membership).
  many :tags, proc { |tags| tags.select { |t| t.visible_to?(Current.membership) } }, serializer: TagSerializer
end
