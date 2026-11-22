# Address folders (docs/plans/address-folders.md in inbox2/internal): a member's
# mail split by the address it came in to. Nothing is stored per folder; a
# thread's folder is read from its addresses:
#
#   inbox            mail for you: your own untagged mail, threads assigned or
#                    granted to you, and shared addresses you show in Inbox
#   <base>           your own address on the domain (waseem)
#   <base>+<tag>     a tag on it (waseem+receipts), out of Inbox by default
#   <shared>         a shared address on the domain's list (info, support)
#   other            everything else on the domain you can see
#
# A thread's address is its to_address when that is on the domain (inbound),
# else its from_address (a thread you started). Sealed threads carry neither
# and fall back to their owner stamp: yours → your folder, else other.
class AddressFolders
  INBOX = "inbox".freeze
  OTHER = "other".freeze
  # Folder keys that are not addresses. An address with one of these names
  # (rare: a mailbox called "inbox") has no folder of its own; its mail is in
  # Other, and a domain can't list one as shared (Domain validation).
  RESERVED = [INBOX, OTHER].freeze
  KIND_INBOX = "inbox".freeze
  KIND_OWN = "own".freeze
  KIND_TAG = "tag".freeze
  KIND_SHARED = "shared".freeze
  KIND_OTHER = "other".freeze

  PREF_INBOX = "inbox".freeze
  PREF_NOTIFY = "notify".freeze

  # The thread's folder address, lowercase and bare: the first address-shaped
  # token, so "Name <a@b>" reads as a@b.
  BARE = %q('[^<>[:space:],"]+@[^<>[:space:],"]+').freeze
  TO_SQL = "LOWER(substring(conversations.to_address FROM #{BARE}))".freeze
  FROM_SQL = "LOWER(substring(conversations.from_address FROM #{BARE}))".freeze
  ADDR_SQL = "(CASE WHEN split_part(#{TO_SQL}, '@', 2) = LOWER(domains.name) THEN #{TO_SQL} ELSE #{FROM_SQL} END)".freeze
  LOCAL_SQL = "split_part(#{ADDR_SQL}, '@', 1)".freeze
  BASE_SQL = "split_part(#{LOCAL_SQL}, '+', 1)".freeze
  # Everything after the first "+", like Mailbox.tag_of (boss+travel+2026 → travel+2026).
  TAG_SQL = "NULLIF(substring(#{LOCAL_SQL} FROM position('+' IN #{LOCAL_SQL}) + 1), #{LOCAL_SQL})".freeze

  attr_reader :membership, :domain

  def initialize(membership, domain)
    @membership = membership
    @domain = domain
  end

  # Shared addresses an admin put on the domain's list, plus any address on it
  # this member was given send-as for. Local parts, lowercase.
  def shared_locals
    @shared_locals ||= begin
      listed = Array(domain.shared_addresses).filter_map { |a| a["local_part"].to_s.downcase.presence }
      granted = membership.send_as_addresses.filter_map do |a|
        local, host = a.split("@", 2)
        local if host == domain.name.downcase
      end
      (listed + granted.map { |l| Mailbox.base_local_part(l) }).uniq - own_locals - RESERVED
    end
  end

  # This member's own address locals on the domain: their mailboxes and username.
  def own_locals
    @own_locals ||= (membership.mailboxes.where(domain_id: domain.id).pluck(:local_part) +
      [membership.user.username.to_s]).map(&:downcase).reject(&:blank?).uniq - RESERVED -
      Array(domain.shared_addresses).map { |a| a["local_part"] }
  end

  def address(local) = "#{local}@#{domain.name}".downcase

  def can_reply?(local) = membership.can_send_as?(address(local))

  def prefs_for(local)
    (membership.folder_prefs || {}).fetch(address(local), {})
  end

  # Whether a shared address or tag folder shows in Inbox. Default: a shared
  # address for those who can reply as it; a tag never.
  def in_inbox?(local)
    pref = prefs_for(local)[PREF_INBOX]
    return pref unless pref.nil?

    Mailbox.tag_of(local) ? false : can_reply?(local)
  end

  # Bell: Inbox on, every other folder off, until the member flips it.
  def notify?(local)
    prefs_for(local)[PREF_NOTIFY] == true
  end

  def inbox_notify?
    pref = (membership.folder_prefs || {}).dig(INBOX, PREF_NOTIFY)
    pref.nil? ? true : pref
  end

  # Whether a new message in this thread rings the member's phone: it is in
  # their Inbox with the Inbox bell on, or in a folder whose bell they turned on.
  # `thread` is the member's visible scope narrowed to the one conversation.
  def notify_for?(thread)
    return true if inbox_notify? && scope(thread, INBOX).exists?

    host = "@#{domain.name.downcase}"
    rung = (membership.folder_prefs || {}).filter_map do |addr, p|
      addr.delete_suffix(host) if p[PREF_NOTIFY] == true && addr.end_with?(host)
    end
    rung.any? { |local| scope(thread, local).exists? }
  end

  # The scope for one folder, over threads the member can already see.
  def scope(visible, folder)
    base = visible.joins(:domain).where(domain_id: domain.id)
    me = membership.id
    case folder
    when INBOX then inbox_scope(base)
    when OTHER
      base.where("conversations.personal_membership_id IS DISTINCT FROM ?", me)
        .where("#{BASE_SQL} IS NULL OR #{BASE_SQL} NOT IN (?)", (shared_locals + own_locals).presence || [""])
    else
      local = folder.to_s.downcase
      b = Mailbox.base_local_part(local)
      tag = Mailbox.tag_of(local)
      if own_locals.include?(b)
        own_threads = mine(base)
        if tag
          own_threads.where("#{BASE_SQL} = ? AND #{TAG_SQL} = ?", b, tag)
        elsif b == own_locals.first
          # The first own address also takes your personal mail whose address is
          # not one of yours: sealed, stamped yours as a co-recipient, or sent
          # by you to a tagged address that is not yours (info+x@).
          own_threads.where("(#{BASE_SQL} = ? AND #{TAG_SQL} IS NULL) OR #{BASE_SQL} IS NULL OR #{BASE_SQL} NOT IN (?)", b, own_locals)
        else
          own_threads.where("#{BASE_SQL} = ? AND #{TAG_SQL} IS NULL", b)
        end
      elsif shared_locals.include?(b)
        base.where("conversations.personal_membership_id IS DISTINCT FROM ?", me).where("#{BASE_SQL} = ?", b)
      else
        base.none
      end
    end
  end

  # Your own untagged mail (and tags you show in Inbox), threads assigned or
  # granted to you, and the shared addresses you show in Inbox.
  def inbox_scope(base)
    me = membership.id
    tags_in = tag_folders(base).select { |t| in_inbox?(t) }
    shared_in = shared_locals.select { |l| in_inbox?(l) }
    own = mine(base)
    # Tags on your own addresses stay out unless chosen; anything else of yours is in.
    own = own.where("#{TAG_SQL} IS NULL OR #{BASE_SQL} NOT IN (?) OR #{LOCAL_SQL} IN (?)", own_locals, tags_in.presence || [""])
    granted = ConversationAccess.where(membership_id: me).select(:conversation_id)
    assigned = ConversationAssignee.where(membership_id: me).select(:conversation_id)
    out = own.or(base.where(id: granted)).or(base.where(id: assigned))
    # Untagged only: info+press@ stays in the info folder, out of Inbox, like your own tags.
    out = out.or(base.where("conversations.personal_membership_id IS NULL").where("#{BASE_SQL} IN (?) AND #{TAG_SQL} IS NULL", shared_in)) if shared_in.any?
    out
  end

  # Your personal threads: stamped yours, or unstamped and addressed to one of
  # your own addresses (older mail; visible_to matches it by address too).
  def mine(base)
    base.where(personal_membership_id: membership.id)
      .or(base.where(personal_membership_id: nil).where("#{BASE_SQL} IN (?)", own_locals.presence || [""]))
  end

  # Tag folders under the member's own addresses that hold mail: "waseem+receipts".
  def tag_folders(visible)
    joined = visible.joins_values.include?(:domain) ? visible : visible.joins(:domain)
    (@tag_folders ||= {})[visible.to_sql] ||= mine(joined.where(domain_id: domain.id)).reorder(nil)
      .where("#{TAG_SQL} IS NOT NULL").where("#{BASE_SQL} IN (?)", own_locals.presence || [""])
      .distinct.pluck(Arel.sql("#{BASE_SQL} || '+' || #{TAG_SQL}")).compact.sort
  end

  # The tree for one domain, with open-unread counts. `visible` is the
  # member's visible_conversations; `open` narrows to the Inbox statuses.
  def tree(visible)
    open = visible.where(status: Conversation::STATUS_OPEN, read: false)
    count = ->(folder) { scope(open, folder).count }
    seen = scope(visible, OTHER).limit(1).exists?
    folders = [{ key: INBOX, kind: KIND_INBOX, address: nil, parent: nil, unread: count.(INBOX),
                 can_reply: true, in_inbox: true, notify: inbox_notify? }]
    own_locals.each do |l|
      next unless l == own_locals.first || can_reply?(l)

      folders << folder(l, KIND_OWN, nil, count)
      tag_folders(visible).select { |t| Mailbox.base_local_part(t) == l }.each { |t| folders << folder(t, KIND_TAG, l, count) }
    end
    shared_locals.each do |l|
      next unless membership.all_domains_access? || can_reply?(l) || scope(visible, l).limit(1).exists?

      folders << folder(l, KIND_SHARED, nil, count)
    end
    folders << { key: OTHER, kind: KIND_OTHER, address: nil, parent: nil, unread: count.(OTHER),
                 can_reply: false, in_inbox: false, notify: false } if seen
    folders
  end

  private

  def folder(local, kind, parent, count)
    { key: local, kind: kind, address: address(local), parent: parent, unread: count.(local),
      can_reply: can_reply?(local), in_inbox: kind == KIND_OWN || in_inbox?(local), notify: notify?(local) }
  end
end
