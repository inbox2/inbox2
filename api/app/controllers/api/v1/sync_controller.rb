module Api
  module V1
    # MX sync — feeds the clients' local mirror (docs/MX-Sync.md, spec 16.7).
    #
    #   GET sync/head      cursor for "now" — recorded before a first backfill
    #   GET sync/pull      forward delta from a cursor
    #   GET sync/backfill  history, newest first
    #   GET sync/keys      every visible thread + its version, for reconcile
    #   GET sync/threads   whole threads by key — hydrates what reconcile/pull flagged
    #
    # The cursor walks `change_xid` (the writing transaction), not a timestamp or a
    # bare sequence: a pull only returns rows written by transactions older than the
    # oldest one still in flight, so a slow commit can never land behind a cursor
    # that already moved past it. `change_seq` orders rows inside that window and is
    # each record's version. Both are stamped by triggers (SyncTriggers).
    #
    # Read-only. Writes go through the normal endpoints, which own validation,
    # activity events and broadcasts.
    class SyncController < BaseController
      include SyncCursor

      before_action :require_organization!

      DEFAULT_LIMIT = 200
      MAX_LIMIT = 500
      BACKFILL_DEFAULT = 50
      BACKFILL_MAX = 200
      KEYS_LIMIT = 5000
      THREADS_MAX = 50
      # Bodies dominate the payload; a page stops early once it carries this much.
      BYTE_BUDGET = 4.megabytes

      CURSOR_SOURCES = {
        "conversation" => "conversations",
        "message" => "messages",
        "note" => "notes",
        "tombstone" => "sync_tombstones"
      }.freeze

      def head
        render json: { cursor: encode_cursor(horizon, 0) }
      end

      def pull
        xid, seq = decode_cursor(params[:since])
        return render_bad_cursor if xid.nil?

        limit = clamp(params[:limit], DEFAULT_LIMIT, MAX_LIMIT)
        hi = horizon
        # A cursor past every xid this database has handed out was issued by
        # another database: a dump restored into a fresh cluster restarts xids
        # (the Pushleft move, 2026-11-05 — every device's pull came back empty
        # while the unread badge, read live, said 1). Restart at "now" and flag
        # it expired, so the client reconciles whatever it missed meanwhile.
        from_elsewhere = xid > next_xid
        xid, seq = hi, 0 if from_elsewhere
        rows = changed_rows(xid, seq, hi, limit + 1)
        has_more = rows.size > limit
        rows = rows.first(limit)

        page = build_page(rows)
        has_more ||= page[:truncated]
        last = page[:last]

        cursor = next_cursor(has_more, last, hi, xid, seq)

        render json: {
          cursor: cursor,
          has_more: has_more,
          cursor_expired: from_elsewhere || cursor_expired?(xid),
          records: page[:records],
          deleted: page[:deleted]
        }
      end

      # Newest-first by last activity, independent of change tracking (rows that
      # predate it have no change_seq). Same record shapes as `pull`.
      def backfill
        at, key = decode_backfill(params[:before])
        return render_bad_cursor if params[:before].present? && at.nil?

        limit = clamp(params[:limit], BACKFILL_DEFAULT, BACKFILL_MAX)
        scope = visible_conversations.order(updated_at: :desc, key: :desc)
        scope = scope.where("(conversations.updated_at, conversations.key) < (?, ?)", at, key) if at
        convs = scope.limit(limit + 1).to_a
        more = convs.size > limit
        convs = convs.first(limit)

        convs, cut = fit_budget(convs)
        messages = Message.where(conversation_id: convs.map(&:id))
        notes = Note.where(conversation_id: convs.map(&:id))

        tail = convs.last
        render json: {
          next: (more || cut) && tail ? encode_backfill(tail) : nil,
          records: serialize_records(convs, messages, notes)
        }
      end

      def keys
        # Keyset on the public key (E5: numeric ids never leave the API).
        rows = visible_conversations.where("conversations.key > ?", params[:after].to_s).order(:key)
          .limit(KEYS_LIMIT + 1).pluck(:key, :change_seq)
        more = rows.size > KEYS_LIMIT
        rows = rows.first(KEYS_LIMIT)
        render json: {
          keys: rows.map { |key, change_seq| [key, change_seq.to_i] },
          next: more ? rows.last[0] : nil
        }
      end

      # Whole threads, in the same record shapes as pull/backfill (so they carry
      # change_seq + domain_id — conversations#show does not, and a thread hydrated
      # from it would sit at version 0 and be re-fetched by every reconcile).
      # Keys the member can't see are simply absent; `missing` names them so the
      # client can drop them. Over budget → `remaining` comes back for another call.
      def threads
        asked = Array(params[:ids]).map(&:to_s).uniq
        keys = asked.first(THREADS_MAX)
        convs = visible_conversations.where(key: keys).order(updated_at: :desc, key: :desc).to_a
        kept, = fit_budget(convs)

        render json: {
          records: serialize_records(kept, Message.where(conversation_id: kept.map(&:id)),
                                     Note.where(conversation_id: kept.map(&:id))),
          missing: keys - convs.map(&:key),
          remaining: (convs - kept).map(&:key) + asked.drop(THREADS_MAX)
        }
      end

      private

      # One ordered walk across every synced table. `own` lets a transaction see
      # its own writes (only ever non-null under transactional tests; a pull is
      # read-only and holds no xid).
      def changed_rows(xid, seq, hi, limit)
        branches = CURSOR_SOURCES.map do |type, table|
          <<~SQL
            (SELECT '#{type}' AS type, id, change_xid, change_seq FROM #{table}
             WHERE organization_id = :org AND change_seq IS NOT NULL
               AND (change_xid, change_seq) > (:xid, :seq)
               AND (change_xid < :hi OR change_xid = pg_current_xact_id_if_assigned()::text::bigint)
             ORDER BY change_xid, change_seq LIMIT :limit)
          SQL
        end
        sql = ApplicationRecord.sanitize_sql([
          "#{branches.join(' UNION ALL ')} ORDER BY change_xid, change_seq LIMIT :limit",
          { org: current_organization.id, xid: xid, seq: seq, hi: hi, limit: limit }
        ])
        ActiveRecord::Base.connection.select_all(sql).map do |r|
          { type: r["type"], id: r["id"], xid: r["change_xid"], seq: r["change_seq"] }
        end
      end

      def build_page(rows)
        ids = rows.group_by { |r| r[:type] }.transform_values { |rs| rs.map { |r| r[:id] } }
        messages = Message.where(id: ids["message"]).to_a
        notes = Note.where(id: ids["note"]).to_a

        # Trim to the byte budget in cursor order, so the cursor stays truthful.
        sizes = messages.to_h { |m| [m.id, payload_bytes(m)] }
        used = 0
        kept = rows.take_while.with_index do |r, i|
          used += sizes.fetch(r[:id], 0) if r[:type] == "message"
          i.zero? || used <= BYTE_BUDGET
        end
        truncated = kept.size < rows.size
        if truncated
          keep = kept.group_by { |r| r[:type] }.transform_values { |rs| rs.map { |r| r[:id] }.to_set }
          messages.select! { |m| keep.fetch("message", Set[]).include?(m.id) }
          notes.select! { |n| keep.fetch("note", Set[]).include?(n.id) }
          ids = keep.transform_values(&:to_a)
        end

        # Candidates are org-wide; visibility decides records vs deletes. A changed
        # thread the member can't see is reported as deleted — that is how a revoked
        # grant/assignment reaches the device. Children of invisible threads drop.
        changed_conv_ids = Array(ids["conversation"])
        parent_ids = (messages.map(&:conversation_id) + notes.map(&:conversation_id)).uniq
        visible = visible_conversations.where(id: changed_conv_ids + parent_ids).to_a
        visible_ids = visible.map(&:id).to_set
        # (Parents count too: a child changing under a thread that went invisible
        # without a bump of its own — a domain-scope change — still clears it.)
        # Someone else's private import was never on this device, so it needs
        # no tombstone — and emitting one would announce its key and activity.
        gone_keys = current_organization.conversations
          .where(id: (changed_conv_ids + parent_ids).uniq - visible_ids.to_a)
          .where("conversations.private = FALSE OR conversations.owner_membership_id = ?", current_membership.id)
          .pluck(:key)

        messages.select! { |m| visible_ids.include?(m.conversation_id) }
        notes.select! { |n| visible_ids.include?(n.conversation_id) }

        # A deleted message/note is only reported for a thread the member can still
        # see; when the whole thread went, its own tombstone covers the children.
        tombstones = SyncTombstone.where(id: ids["tombstone"]).order(:change_seq).to_a
        child_parents = tombstones.filter_map(&:parent_key)
        seen_parents = child_parents.empty? ? [] : visible_conversations.where(key: child_parents).pluck(:key)
        tombstones.select! { |t| t.parent_key.nil? ? t.record_type == SyncTombstone::TYPE_CONVERSATION : seen_parents.include?(t.parent_key) }
        tombstones +=
          gone_keys.map { |key| SyncTombstone.new(record_type: SyncTombstone::TYPE_CONVERSATION, record_key: key) }
        deleted = tombstones.map { |t| Sync::TombstoneSerializer.new(t).to_h }

        { records: serialize_records(visible, messages, notes), deleted: deleted,
          truncated: truncated, last: kept.last }
      end

      def serialize_records(convs, messages, notes)
        conv_ids = convs.map(&:id)
        convs = Conversation.where(id: conv_ids).includes(:tags, :space, :domain, :lore_member_dones, assignees: :user)
          .in_order_of(:id, conv_ids)
        with_attachments = Attachment.joins(:message).where(messages: { conversation_id: conv_ids })
          .distinct.pluck("messages.conversation_id").to_set
        messages = Message.where(id: messages.map(&:id)).readable_by(current_membership).includes(:attachments, :conversation, :opens)
          .order(:created_at)
        membership_preload = [:user, :domains, { mailboxes: :domain }]
        notes = Note.where(id: notes.map(&:id))
          .includes(:conversation, :parent_note, :replies,
                    { membership: membership_preload }, { reactions: { membership: membership_preload } })
          .order(:created_at)

        {
          conversations: convs.map { |c| Sync::ConversationSerializer.new(c, params: { with_attachments: with_attachments }).to_h },
          messages: messages.map { |m| Sync::MessageSerializer.new(m).to_h },
          notes: notes.map { |n| Sync::NoteSerializer.new(n).to_h }
        }
      end

      # Whole threads only: a backfilled conversation always arrives with all of
      # its messages. At least one thread per page, however large.
      # Sized in SQL, so an oversized page is never loaded just to be thrown away.
      # ponytail: one giant thread is still served whole (as conversations#show
      # does today); page messages inside a thread if that ever bites.
      def fit_budget(convs)
        sizes = Message.where(conversation_id: convs.map(&:id)).group(:conversation_id).sum(Arel.sql(
          "COALESCE(octet_length(body_html), 0) + COALESCE(octet_length(body_plain), 0) + COALESCE(octet_length(body_ciphertext), 0)"
        ))
        used = 0
        kept = convs.take_while.with_index do |c, i|
          used += sizes.fetch(c.id, 0)
          i.zero? || used <= BYTE_BUDGET
        end
        [kept, kept.size < convs.size]
      end

      def payload_bytes(message)
        message.body_html.to_s.bytesize + message.body_plain.to_s.bytesize + message.body_ciphertext.to_s.bytesize
      end

      def cursor_expired?(xid)
        return false if xid.zero?

        watermark = SyncTombstone.watermark_xid(current_organization.id)
        watermark.present? && xid < watermark
      end

      def encode_backfill(conv) = "#{conv.updated_at.utc.iso8601(6)}~#{conv.key}"

      def decode_backfill(raw)
        m = /\A([^~]+)~(conv_[\w-]+)\z/.match(raw.to_s)
        m && [Time.iso8601(m[1]), m[2]]
      rescue ArgumentError
        nil
      end
    end
  end
end
