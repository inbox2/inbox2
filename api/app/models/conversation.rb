class Conversation < ApplicationRecord
  key_prefix "conv"

  STATUSES = %w[open pending archived trash spam].freeze
  STATUS_OPEN = "open".freeze
  STATUS_PENDING = "pending".freeze
  STATUS_ARCHIVED = "archived".freeze
  STATUS_TRASH = "trash".freeze
  STATUS_SPAM = "spam".freeze

  # Statuses hidden from the default inbox/pool listing — a thread that was
  # trashed, marked spam, or archived (on ANY client) must not resurface in the
  # inbox. Mirrors the web `INBOX_HIDDEN_STATUSES` + iOS `ConvStatusValue.inboxHidden`.
  # A client wanting a hidden folder asks for it explicitly via `?status=trash|spam|archived`.
  INBOX_HIDDEN_STATUSES = [STATUS_TRASH, STATUS_SPAM, STATUS_ARCHIVED].freeze

  # A new inbound message threading into one of these pulls the thread back into
  # the inbox (open + unread) — the sender resumed the conversation, so a trashed
  # or archived thread must resurface. Spam is deliberately excluded: it's
  # re-scored per-message at ingest, not revived on activity.
  REVIVABLE_STATUSES = [STATUS_TRASH, STATUS_ARCHIVED].freeze

  # Disposable folders: junk that a user can permanently wipe on demand ("Empty
  # folder") and that PurgeExpiredJunkJob auto-deletes after JUNK_RETENTION.
  # Archived mail is deliberately excluded — it's kept, not disposable.
  EMPTYABLE_STATUSES = [STATUS_TRASH, STATUS_SPAM].freeze
  JUNK_RETENTION = 30.days

  # Lore to-do title (docs/Triage.md "Next-action fields"); the column's limit.
  NEXT_ACTION_TITLE_MAX = 80

  # Deleted or junk: never returned by search. Mirrors the web
  # `DISCARDED_STATUSES` (which filters the local-channel half of the same
  # search). Archived mail stays searchable — it's filed, not discarded.
  DISCARDED_STATUSES = [STATUS_TRASH, STATUS_SPAM].freeze

  belongs_to :organization
  # The domain this thread arrived at (set at inbound from the recipient domain).
  # A thread lives in the org-wide pool but is attributed to one domain, which
  # drives per-member visibility (Conversation.visible_to) and per-domain stats.
  belongs_to :domain, optional: true
  belongs_to :space, optional: true
  # The member a private thread belongs to (docs/plans/mail-import.md D9); set
  # with private: true. Their messages carry the same owner.
  belongs_to :owner, class_name: "Membership", foreign_key: :owner_membership_id, optional: true
  has_many :messages, dependent: :destroy
  has_many :conversation_tags, dependent: :destroy
  has_many :tags, through: :conversation_tags
  has_many :conversation_assignees, dependent: :destroy
  has_many :assignees, through: :conversation_assignees, source: :membership
  has_many :conversation_accesses, dependent: :destroy
  has_many :accessible_members, through: :conversation_accesses, source: :membership
  has_many :notes, dependent: :destroy
  has_many :lore_member_dones # the FK cascades
  has_many :activity_events, dependent: :destroy
  has_many :notifications, dependent: :nullify
  # Both of these hold a DB-level FK to conversations, so a missing dependent
  # rule doesn't just orphan rows — it makes `destroy` raise
  # ActiveRecord::InvalidForeignKey and takes down every caller that purges a
  # thread (the nightly PurgeExpiredJunkJob died on this from 2026-06 onward, and
  # "Empty folder" / GDPR wipe hit the same wall). A rule log is meaningless
  # without its thread and cannot be nullified (conversation_id is NOT NULL);
  # an agent run log carries cost/usage the org is billed on, so it outlives the
  # thread with a null reference.
  has_many :rule_logs, dependent: :destroy
  has_many :agent_run_logs, dependent: :nullify

  STATUSES_WITH_SNOOZED = (STATUSES + %w[snoozed]).freeze

  validates :status, inclusion: { in: STATUSES }

  scope :for_organization, ->(org) { where(organization: org) }

  # Outside every member's pool: imported history (docs/plans/mail-import.md).
  # Org-wide readers that are not a member (MCP agents, API keys, the Explorer
  # graph, rule previews) read through this.
  scope :not_private, -> { where(private: false) }

  # Every member's personal address in the thread's org: their Mailbox rows plus
  # username@ each org domain (the set Membership#teammate_mailbox_addresses
  # builds per member, here for readers that are no one member).
  PERSONAL_ADDRESSES_SQL = <<~SQL.squish.freeze
    SELECT LOWER(mb.local_part || '@' || d.name) FROM mailboxes mb JOIN domains d ON d.id = mb.domain_id
    WHERE d.organization_id = conversations.organization_id
    UNION
    SELECT LOWER(u.username || '@' || d.name) FROM memberships ms JOIN users u ON u.id = ms.user_id
    JOIN domains d ON d.organization_id = ms.organization_id
    WHERE ms.organization_id = conversations.organization_id AND u.username IS NOT NULL
      AND NOT d.shared_addresses @> jsonb_build_array(jsonb_build_object('local_part', LOWER(u.username)))
  SQL

  # What an org-wide reader that is not a member may read (API keys, the
  # Explorer graph, rule previews, Lore mining, the org export): the shared
  # pool minus every member's personal mailbox, which is private to its member
  # (2026-10-24). Inbound threading and live rules keep using not_private.
  scope :org_readable, -> {
    not_private.where(personal_membership_id: nil).where(
      "(conversations.to_address IS NULL OR LOWER(conversations.to_address) NOT IN (#{PERSONAL_ADDRESSES_SQL})) AND " \
      "(conversations.from_address IS NULL OR LOWER(conversations.from_address) NOT IN (#{PERSONAL_ADDRESSES_SQL}))"
    )
  }

  # The slice of the (org-wide) pool a member may see. Owners/admins and
  # all-domains members see every shared thread; a scoped member sees only their granted
  # domains PLUS any thread directly assigned or access-granted to them — those
  # direct grants override domain scoping (one-off cross-domain work). Callers
  # must already be tenant-scoped (current_organization.conversations).
  #
  # A personal mailbox is private to its member, owners and admins included
  # (2026-10-24): threads addressed to/from another member's mailbox address
  # are hidden unless explicitly shared/assigned. Matches the bare envelope
  # recipient stamped at inbound, and personal_membership_id — stamped when the
  # thread starts, and the only attribution a sealed (E2EE) thread carries,
  # since it stores no addresses.
  #
  # A private thread (imported history, docs/plans/mail-import.md) is in no
  # pool, not even an owner's or admin's: only a grant or an assignment shows it.
  #
  # A member always sees mail to or from their own mailboxes, pool grant or not:
  # a rules-only member (no domain grants) still gets their own address.
  scope :visible_to, ->(membership) {
    granted  = ConversationAccess.where(membership_id: membership.id).select(:conversation_id)
    assigned = ConversationAssignee.where(membership_id: membership.id).select(:conversation_id)
    pool = where(private: false)
    pool = pool.where(domain_id: membership.accessible_domain_ids) unless membership.all_domains_access?
    pool = pool.where("conversations.personal_membership_id IS NULL OR conversations.personal_membership_id = ?", membership.id)
    if (addrs = membership.teammate_mailbox_addresses).any?
      pool = pool.where(
        "(conversations.to_address IS NULL OR LOWER(conversations.to_address) NOT IN (:addrs)) AND " \
        "(conversations.from_address IS NULL OR LOWER(conversations.from_address) NOT IN (:addrs))",
        addrs: addrs
      )
    end
    own = membership.email_addresses.map(&:downcase)
    if own.any?
      # name+tag@domain is name@domain's mail (plus addressing).
      untag = ->(col) { "split_part(split_part(LOWER(#{col}), '@', 1), '+', 1) || '@' || split_part(LOWER(#{col}), '@', 2)" }
      pool = pool.or(where(private: false).where(
        "LOWER(conversations.to_address) IN (:own) OR LOWER(conversations.from_address) IN (:own) OR " \
        "#{untag.('conversations.to_address')} IN (:own)", own: own
      ))
    end
    pool
      .or(where(private: false, personal_membership_id: membership.id))
      .or(where(id: granted))
      .or(where(id: assigned))
  }

  # A member's own mail, and nothing of the team's: threads stamped as their
  # personal mail when they started, and private (imported) threads they own.
  # This is what a mail client is served (docs/Mail-Clients.md). Ownership
  # only: a thread that merely names their address, or was shared with them by
  # a grant, is the team's or a colleague's, and a mail client could change it.
  scope :personal_to, ->(membership) {
    where(private: false, personal_membership_id: membership.id)
      .or(where(private: true, owner_membership_id: membership.id))
  }

  # `update_all` over several threads, taking the row locks in id order first.
  # A bare update_all locks in heap order; the sync triggers (SyncTriggers) lock
  # parents in id order. Two lock orders over the same rows is a deadlock waiting
  # for a bulk archive to meet a merge — measured at 50 deadlocks per 1200 writes
  # in script/mx_sync_stress.rb, 2 with this. Any new multi-thread write uses it.
  def self.update_all_in_order(scope, attrs)
    transaction do
      scope.reorder(:id).lock("FOR NO KEY UPDATE").pluck(:id)
      scope.update_all(attrs)
    end
  end

  # A compose draft's thread is private to its author (DraftsController#create)
  # until something in it is sent. Imported private history always holds sent
  # or received mail, so it never matches.
  # Sent, and nothing has come in yet. The thread stays open, because Lore's
  # Waiting list reads open threads, but the Inbox skips it. Mail you sent is read;
  # the first reply is what lands in the Inbox as new.
  def refresh_sent_only!
    received = messages.where(is_inbound: true).exists?
    now = !received && messages.where(is_draft: false).exists?
    return if now == sent_only

    update_columns(if now then { sent_only: true, read: true }
    elsif received then { sent_only: false, read: false }
    else { sent_only: false }
    end)
  end

  def publish_draft_thread!
    return unless private && messages.where(is_draft: false).none?

    update!(private: false, owner_membership_id: nil)
  end

  # The reverse, when a cancelled send leaves nothing sent in the thread —
  # unless a colleague has a draft in it, which would strand theirs.
  def privatize_draft_thread!(membership)
    return if membership.nil? || private || messages.where(is_draft: false).exists?
    return if messages.where(is_draft: true).where.not(owner_membership_id: membership.id).exists?

    update!(private: true, owner_membership_id: membership.id)
    ConversationAccess.find_or_create_by!(conversation: self, membership: membership)
  end

  before_save :update_search_vector, if: -> { subject_changed? || snippet_changed? || from_address_changed? || to_address_changed? }

  private

  def update_search_vector
    text = [subject, snippet, from_address, to_address].compact.join(" ")
    self.search_vector = Conversation.connection.execute(
      Conversation.sanitize_sql(["SELECT to_tsvector('english', ?)", text])
    ).first["to_tsvector"]
  end
end
