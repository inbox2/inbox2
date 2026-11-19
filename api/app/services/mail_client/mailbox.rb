# One person's mailbox as a mail client sees it (docs/Mail-Clients.md): five
# folders over their own mail, with stable UIDs.
#
# inbox2 has no folders: a thread has a status. So a message's folder is
# derived, and `reconcile!` brings the stored UIDs in line with it each time a
# client looks. A message that changed folder gets a fresh UID there, which is
# what IMAP expects of a move.
module MailClient
  class Mailbox
    INBOX = "INBOX".freeze
    ARCHIVE = "Archive".freeze
    SENT = "Sent".freeze
    TRASH = "Trash".freeze
    JUNK = "Junk".freeze
    SPECIAL_USE = { INBOX => nil, ARCHIVE => "\\Archive", SENT => "\\Sent", TRASH => "\\Trash", JUNK => "\\Junk" }.freeze
    FOLDERS = SPECIAL_USE.keys.freeze
    # Moving a message into a folder sets its thread to this status.
    # Sent is a target only for a sent message coming back out of Trash.
    STATUS_FOR = { INBOX => Conversation::STATUS_OPEN, ARCHIVE => Conversation::STATUS_ARCHIVED,
                   TRASH => Conversation::STATUS_TRASH, JUNK => Conversation::STATUS_SPAM,
                   SENT => Conversation::STATUS_OPEN }.freeze
    FOLDER_SQL = <<~SQL.squish.freeze
      CASE WHEN conversations.status = '#{Conversation::STATUS_TRASH}' THEN '#{TRASH}'
           WHEN NOT messages.is_inbound THEN '#{SENT}'
           WHEN conversations.status = '#{Conversation::STATUS_SPAM}' THEN '#{JUNK}'
           WHEN conversations.status = '#{Conversation::STATUS_ARCHIVED}' THEN '#{ARCHIVE}'
           ELSE '#{INBOX}' END
    SQL
    SEEN = "\\Seen".freeze
    DELETED = "\\Deleted".freeze
    LOCK_NAMESPACE = 0x494d4150 # "IMAP"

    def initialize(membership)
      @membership = membership
      @org = membership.organization
    end

    # The person's own mail that a client may see: no drafts, nothing sealed.
    def messages_scope
      Message.joins(:conversation)
        .merge(@org.conversations.personal_to(@membership))
        .where(is_draft: false, encryption_scheme: Message::ENCRYPTION_SCHEME_NONE)
    end

    # ponytail: runs on every client poll and reads the person's whole mailbox
    # index. Fine to tens of thousands of messages; past that, drive it from the
    # sync change feed (change_seq) so a poll only looks at what changed.
    def reconcile!
      ImapMessage.transaction do
        conn = ImapMessage.connection
        conn.execute("SELECT pg_advisory_xact_lock(#{LOCK_NAMESPACE}, #{@membership.id.to_i})")
        mine.where.not(message_id: messages_scope.select(:id)).delete_all
        changed = conn.select_rows(<<~SQL)
          SELECT d.message_id, d.folder
          FROM (#{messages_scope.select("messages.id AS message_id, #{FOLDER_SQL} AS folder").to_sql}) d
          LEFT JOIN imap_messages im ON im.membership_id = #{@membership.id.to_i} AND im.message_id = d.message_id
          WHERE im.id IS NULL OR im.folder <> d.folder
          ORDER BY d.message_id
        SQL
        next if changed.empty?

        folders = folder_rows
        rows = changed.map do |message_id, folder|
          row = folders.fetch(folder)
          uid = row.uidnext
          row.uidnext += 1
          { membership_id: @membership.id, message_id: message_id, folder: folder, uid: uid, expunged: false }
        end
        rows.each_slice(1000) do |slice|
          ImapMessage.upsert_all(slice, unique_by: %i[membership_id message_id], update_only: %i[folder uid expunged])
        end
        folders.each_value { |f| f.save! if f.changed? }
      end
    end

    def folders
      reconcile!
      exists = visible.group(:folder).count
      unseen = visible.joins(message: :conversation).where(conversations: { read: false }).group(:folder).count
      rows = folder_rows
      FOLDERS.map do |name|
        { name: name, special_use: SPECIAL_USE[name], uidvalidity: rows[name].uidvalidity, uidnext: rows[name].uidnext,
          exists: exists[name].to_i, unseen: unseen[name].to_i }
      end
    end

    def list(folder)
      reconcile!
      row = folder_rows.fetch(check(folder))
      fill_sizes(folder)
      messages = in_folder(folder).joins(message: :conversation).order(:uid)
        .pluck(:uid, :flags, "messages.created_at", :size, "conversations.read")
        .map { |uid, flags, at, size, read| { uid: uid, flags: with_seen(flags, read), internal_date: at.utc.iso8601, size: size } }
      { uidvalidity: row.uidvalidity, uidnext: row.uidnext, messages: messages }
    end

    def find(folder, uid)
      in_folder(check(folder)).includes(message: :attachments).find_by!(uid: uid)
    end

    def store_flags(folder, uids, mode, flags)
      rows = in_folder(check(folder)).where(uid: uids)
      flags = Array(flags).map(&:to_s).uniq
      raise Refused, "mode must be add, remove or set" unless %w[add remove set].include?(mode)

      if flags.include?(SEEN) || mode == "set"
        read = mode == "remove" ? false : flags.include?(SEEN)
        threads = @org.conversations.where(id: Message.where(id: rows.select(:message_id)).select(:conversation_id))
        Conversation.update_all_in_order(threads.where.not(read: read), read: read)
        MobileBadgeRefreshJob.perform_later(@org.id)
      end
      own = flags - [SEEN]
      rows.each do |row|
        updated = case mode
        when "add" then row.flags | own
        when "remove" then row.flags - own
        else own
        end
        row.update!(flags: updated) if updated != row.flags
      end
      in_folder(folder).where(uid: uids).joins(message: :conversation).order(:uid)
        .pluck(:uid, :flags, "conversations.read").map { |uid, f, read| { uid: uid, flags: with_seen(f, read) } }
    end

    # Moves whole threads: the folder is the thread's status. A sent message
    # lives in Sent or Trash and nowhere else, and a received one never in
    # Sent. A message the move cannot place is left alone, thread and all, and
    # is absent from the result.
    def move(folder, uids, to)
      status = STATUS_FOR[to] or raise Refused, "Messages cannot be moved to #{to}"
      rows = in_folder(check(folder)).where(uid: uids).joins(:message).pluck(:uid, :message_id, "messages.is_inbound")
        .select { |_, _, inbound| inbound ? to != SENT : (to == TRASH || (to == SENT && folder == TRASH)) }
        .map { |uid, message_id, _| [uid, message_id] }
      return [] if rows.empty?

      set_status(rows.map(&:last), status, from: folder)
      reconcile!
      new_uids = mine.where(message_id: rows.map(&:last), folder: to).pluck(:message_id, :uid).to_h
      rows.filter_map { |uid, message_id| { uid: uid, to_uid: new_uids[message_id] } if new_uids[message_id] }
    end

    # Outside Trash an expunge moves the thread to Trash, where it can be
    # recovered. Inside Trash it only hides the message from mail clients:
    # removing mail for good stays with inbox2 itself.
    def expunge(folder, uids = nil)
      rows = in_folder(check(folder)).where("? = ANY(flags)", DELETED)
      rows = rows.where(uid: uids) if uids.present?
      found = rows.pluck(:uid, :message_id)
      return [] if found.empty?

      if folder == TRASH
        mine.where(message_id: found.map(&:last)).update_all(expunged: true)
      else
        mine.where(message_id: found.map(&:last)).update_all(["flags = array_remove(flags, ?)", DELETED])
        set_status(found.map(&:last), Conversation::STATUS_TRASH, from: folder)
        reconcile!
      end
      found.map(&:first)
    end

    # ponytail: substring match over the folder's rows, no index. Move TEXT to
    # messages.search_vector when a mailbox is large enough to notice.
    def search(folder, criteria)
      reconcile!
      scope = in_folder(check(folder)).joins(:message)
      like = ->(v) { "%#{Message.sanitize_sql_like(v.to_s)}%" }
      scope = scope.where("messages.from_address ILIKE ?", like[criteria[:from]]) if criteria[:from].present?
      if criteria[:to].present?
        scope = scope.where("messages.to_address ILIKE :q OR messages.cc_address ILIKE :q", q: like[criteria[:to]])
      end
      scope = scope.where("messages.subject ILIKE ?", like[criteria[:subject]]) if criteria[:subject].present?
      if criteria[:text].present?
        scope = scope.where("messages.subject ILIKE :q OR messages.body_plain ILIKE :q OR messages.from_address ILIKE :q", q: like[criteria[:text]])
      end
      scope = scope.where("messages.created_at >= ?", Date.iso8601(criteria[:since].to_s)) if criteria[:since].present?
      scope = scope.where("messages.created_at < ?", Date.iso8601(criteria[:before].to_s)) if criteria[:before].present?
      scope.order(:uid).pluck(:uid)
    rescue Date::Error
      raise Refused, "since and before must be dates (YYYY-MM-DD)"
    end

    # A mail client files its own copy of what it just sent. The message is
    # already here (it was submitted through us), so there is nothing to store;
    # anything else is refused, because mail cannot be imported this way.
    def append(folder, raw)
      check(folder)
      message_id = raw.to_s[/^Message-I[dD]:\s*(<[^>\r\n]+>)/i, 1]
      raise Refused, "Only a copy of a message you sent can be saved here" if message_id.blank?

      reconcile!
      row = mine.joins(:message).find_by(messages: { message_id_header: message_id })
      raise Refused, "Only a copy of a message you sent can be saved here" unless row

      row.folder == folder ? row.uid : nil
    end

    private

    def mine = ImapMessage.where(membership_id: @membership.id)
    def visible = mine.where(expunged: false)
    def in_folder(folder) = visible.where(folder: folder)

    def check(folder)
      raise ActiveRecord::RecordNotFound, "No such folder" unless FOLDERS.include?(folder)

      folder
    end

    def with_seen(flags, read) = read ? flags | [SEEN] : flags

    def folder_rows
      scope = ImapFolder.where(membership_id: @membership.id)
      existing = scope.index_by(&:name)
      missing = FOLDERS - existing.keys
      return existing if missing.empty?

      ImapFolder.insert_all(missing.map { |name| { membership_id: @membership.id, name: name, uidvalidity: Time.current.to_i } },
        unique_by: %i[membership_id name])
      scope.reload.index_by(&:name)
    end

    # RFC822.SIZE for rows that do not have one yet. Computed without fetching
    # attachments (MailClient::Mime#size).
    def fill_sizes(folder)
      in_folder(folder).where(size: nil).includes(message: :attachments).find_each do |row|
        row.update_column(:size, Mime.new(row.message).size)
      end
    end

    def set_status(message_ids, status, from:)
      threads = @org.conversations.where(id: Message.where(id: message_ids).select(:conversation_id)).where.not(status: status)
      ids = threads.pluck(:id)
      return if ids.empty?

      Conversation.update_all_in_order(threads, status: status)
      # The junk filter learns from a move into Junk, and from a move back out.
      SpamFeedbackJob.perform_later(ids, true) if status == Conversation::STATUS_SPAM
      SpamFeedbackJob.perform_later(ids, false) if from == JUNK && status != Conversation::STATUS_SPAM
      MobileBadgeRefreshJob.perform_later(@org.id)
    end
  end
end
