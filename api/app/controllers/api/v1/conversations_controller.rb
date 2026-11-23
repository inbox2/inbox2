module Api
  module V1
    class ConversationsController < BaseController
      include RecordsActivity
      before_action :require_organization!

      EMPTY_FOLDER_SYNC_LIMIT = 200
      # Any of these makes a listing something other than the Inbox.
      NOT_INBOX_PARAMS = %i[direction is_draft labeled triage_label lore_done mentioned view_id include_sent].freeze

      # spec 3.1.1, 3.4.1, A6.1
      def index
        conversations = visible_conversations
          .includes(:tags, :space, :lore_member_dones, assignees: :user)
          .order(updated_at: :desc)

        if params[:status].present?
          conversations = conversations.where(status: params[:status])
        else
          # Inbox/pool default: never surface trashed, spam, or archived threads.
          # Clients that send no status for the inbox (iOS/Android) would otherwise
          # see a thread hidden on another client — a hidden folder is requested
          # explicitly via ?status=… (the branch above).
          conversations = conversations.where.not(status: Conversation::INBOX_HIDDEN_STATUSES)
        end

        conversations = conversations.where(sent_only: false) if inbox_listing?

        conversations = filter_by_space_and_domain(conversations)
        conversations = filter_by_folder(conversations)
        conversations = conversations.where(to_address: params[:to]) if params[:to].present?
        conversations = conversations.where(from_address: params[:from]) if params[:from].present?

        # Label filter (sidebar LABELS): narrow to threads carrying any of the
        # named tags (OR among labels), AND-ed with the folder/status above.
        # Accepts tags[]=A&tags[]=B (multi-select) or tag=A (single). Tenant-
        # scoped already via visible_conversations.
        tag_names = (Array(params[:tags]) + Array(params[:tag])).flatten.reject(&:blank?).uniq
        if tag_names.any?
          # A subquery, not joins(:tags): with the row-level includes(:tags) a
          # join on the same table turns into eager_load and each row's `tags`
          # shrinks to the filtered label — the chip list showed one tag.
          tagged = ConversationTag.joins(:tag)
            .where(tags: { name: tag_names, membership_id: [nil, current_membership&.id].uniq })
            .select(:conversation_id)
          conversations = conversations.where(id: tagged)
        end

        # Triage label filter: triage_label=x or triage_label[]=a&triage_label[]=b.
        triage_labels = Array(params[:triage_label]).flatten.map(&:to_s).reject(&:blank?).uniq
        conversations = conversations.where(triage_label: triage_labels) if triage_labels.any?
        # labeled=true: any label but resolved, custom org labels included (mobile Lore
        # filters before paging; it can't list an org's custom slugs).
        if params[:labeled] == "true"
          conversations = conversations.where.not(triage_label: nil).where.not(triage_label: TriageLabel::RESOLVED)
        end

        # Lore: lore_done=false leaves out what this member ticked off (Today), =true lists only that (History).
        if params[:lore_done].present?
          mine = LoreMemberDone.where(membership_id: current_membership&.id).select(:conversation_id)
          conversations = params[:lore_done] == "true" ? conversations.where(id: mine) : conversations.where.not(id: mine)
        end

        if params[:read].present?
          conversations = conversations.where(read: params[:read] == "true")
        end

        # Sent: threads that have a delivered (non-draft) outbound message.
        if params[:direction] == "outbound"
          conversations = conversations
            .joins(:messages)
            .where(messages: { is_inbound: false, is_draft: false })
            .distinct
        end

        # Drafts: threads that have one of the caller's unsent drafts.
        if params[:is_draft].to_s == "true"
          conversations = conversations
            .joins(:messages)
            .where(messages: { is_draft: true, owner_membership_id: current_membership&.id })
            .distinct
        end

        # Mentioned: threads where the caller has a mention notification.
        if params[:mentioned] == "me"
          conversations = conversations
            .joins(:notifications)
            .where(notifications: { user_id: current_user.id, kind: Notification::KIND_MENTION })
            .distinct
        end

        # Assignee filter for the system views: "me" (assigned to the caller),
        # "none"/"unassigned" (no assignee), or a specific membership key.
        if params[:assignee].present?
          conversations = filter_by_assignee(conversations, params[:assignee])
        end

        # Pagination (spec 3.4.6)
        conversations, meta = paginate(conversations, default_per_page: 25, max_per_page: 100)

        render json: { conversations: conversation_rows(conversations), meta: meta }
      end

      # spec 3.1.4, 4.1.1, A6.2
      def show
        # MembershipSerializer walks user + domains + mailboxes→domain for every
        # membership it renders (assignees, note authors, reaction members) —
        # preload the same set MembersController#index does or each one N+1s.
        membership_preload = [:user, :domains, { mailboxes: :domain }]
        # Tracked messages render opens + links + clicks (MessageSerializer); a
        # 30-message tracked thread used to be ~150 queries.
        conversation = visible_conversations
          .includes(:tags, { messages: [:attachments, :opens, { tracked_links: :clicks }] }, { assignees: membership_preload },
                    { notes: [{ membership: membership_preload }, :parent_note, :replies,
                              { reactions: { membership: membership_preload } }] })
          .find_by!(key: params[:id])

        render json: { conversation: ConversationDetailSerializer.new(conversation).to_h }
      end

      # spec 4.2.2, 4.2.6, 6.1.2, A6.3
      def update
        conversation = visible_conversations.find_by!(key: params[:id])

        if conversation.update(conversation_update_params)
          # Read state moved → the other devices' app-icon badges are stale.
          refresh_mobile_badge unless params[:read].nil?
          # Marking a thread read is a triage action worth attributing (covers the
          # dwell-based auto-read + explicit mark-read on a single thread).
          record_activity(ActivityEvent::ACTION_READ, conversation: conversation) if params[:read].to_s == "true"
          render json: { conversation: ConversationSerializer.new(conversation.reload).to_h }
        else
          render json: ErrorSerializer.serialize(conversation.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # spec 6.2.2, A9.2
      def update_tags
        conversation = visible_conversations.find_by!(key: params[:id])

        # add_tag_ids / remove_tag_ids change only the named tags, so a client
        # working from a stale copy can't undo a teammate's tag. tag_ids replaces
        # the whole set (the tag picker's shape).
        # Only tags the member can see; a full replace keeps the private labels
        # of others, which the client never had.
        tags = current_organization.tags.visible_to(current_membership)
        if params.key?(:add_tag_ids) || params.key?(:remove_tag_ids)
          added = tags.where(key: Array(params[:add_tag_ids]))
          removed = tags.where(key: Array(params[:remove_tag_ids]))
          conversation.tags << (added - conversation.tags)
          conversation.tags.delete(removed)
        else
          hidden = conversation.tags.reject { |t| t.visible_to?(current_membership) }
          conversation.tags = tags.where(key: params[:tag_ids] || []).to_a + hidden
        end

        render json: { conversation: ConversationSerializer.new(conversation.reload).to_h }
      end

      # Manually move a thread into a Space (or clear it). Mirrors update_tags:
      # the client sends a space key (or null/empty to unset). Any of the org's
      # spaces is a valid target, including the Triage holding pen. A space key
      # that isn't this org's 404s (E3 tenant isolation).
      def update_space
        conversation = visible_conversations.find_by!(key: params[:id])

        if params[:space_id].present?
          space = current_organization.spaces.find_by(key: params[:space_id])
          return render json: ErrorSerializer.serialize("Space not found", status: 404), status: :not_found unless space
          conversation.update!(space_id: space.id)
        else
          conversation.update!(space_id: nil)
        end

        render json: { conversation: ConversationSerializer.new(conversation.reload).to_h }
      end

      # Manually set the thread's triage label (docs/Triage.md "Manual triage").
      # Any of the org's ENABLED labels; recorded as source "manual". The next
      # inbound message (or an explicit retriage) lets Jev judge it again.
      def update_triage_label
        conversation = visible_conversations.find_by!(key: params[:id])
        label = params[:label].to_s
        labels = TriageLabel.ensure_defaults(current_organization)
        unless labels.any? { |l| l.enabled && l.slug == label }
          return render json: ErrorSerializer.serialize("Unknown or disabled label", status: 422), status: :unprocessable_content
        end

        latest = conversation.messages.where(is_inbound: true).order(created_at: :desc).first
        conversation.update!(triage_label: label, triage_source: TriageLabel::SOURCE_MANUAL,
                             **SpaceClassifier.new(conversation.organization).next_action_attributes(conversation, latest, label))
        render json: { conversation: ConversationSerializer.new(conversation.reload).to_h }
      end

      # "Re-run Jev": re-judge label + priority (and the Space while the thread
      # has none — a manual Space sticks) off the request path. new_thread=false:
      # no summary rewrite, no duplicate mobile push.
      def retriage
        conversation = visible_conversations.find_by!(key: params[:id])
        org = conversation.organization
        latest = conversation.messages.where(is_inbound: true).order(created_at: :desc).first

        error, status =
          if !org.ai_triage_enabled? || !SpaceClassifier.enabled?
            ["AI triage isn't available for this organization", :unprocessable_content]
          elsif Conversation::INBOX_HIDDEN_STATUSES.include?(conversation.status)
            ["Only threads in the inbox are triaged", :unprocessable_content]
          elsif latest.nil? || latest.sealed?
            # Sealed mail can't be re-read server-side (docs/E2EE.md).
            ["This thread has no message the server can triage", :unprocessable_content]
          elsif !TriageBreaker.new(org).allow?
            # ponytail: org cap only; the job still enforces domain/user caps.
            ["AI triage limit reached for this month", :too_many_requests]
          end
        if error
          code = Rack::Utils.status_code(status)
          return render json: ErrorSerializer.serialize(error, status: code), status: status
        end

        ClassifySpaceJob.perform_later(conversation.id, false)
        render json: { conversation: ConversationSerializer.new(conversation).to_h }, status: :accepted
      end

      # spec 3.4.3, A6.4
      def bulk
        ids = params[:conversation_ids] || []
        conversations = visible_conversations.where(key: ids)

        if conversations.empty?
          return render json: ErrorSerializer.serialize("No conversations found", status: 422), status: :unprocessable_content
        end

        action = params[:action_name]
        # Snapshot keys + records before update_all so a removal push can target
        # threads that just left the inbox (the relation is re-read lazily
        # otherwise) and so activity is attributed to the pre-mutation rows.
        affected = conversations.to_a
        affected_keys = affected.map(&:key)
        case action
        when "archive"
          Conversation.update_all_in_order(conversations, status: Conversation::STATUS_ARCHIVED)
          clear_mobile_notifications(affected_keys)
          record_activity(ActivityEvent::ACTION_ARCHIVED, conversations: affected)
        when "trash"
          Conversation.update_all_in_order(conversations, status: Conversation::STATUS_TRASH)
          clear_mobile_notifications(affected_keys)
          record_activity(ActivityEvent::ACTION_DELETED, conversations: affected)
        when "spam"
          Conversation.update_all_in_order(conversations, status: Conversation::STATUS_SPAM)
          clear_mobile_notifications(affected_keys)
          # Every "mark as spam" path must feed the Bayes classifier, not just the
          # spam-feedback endpoint — this is the one the clients actually call.
          # One job for the whole list: training is an HTTP round trip each.
          SpamFeedbackJob.perform_later(affected.map(&:id), true)
        when "mark_read"
          Conversation.update_all_in_order(conversations, read: true)
          refresh_mobile_badge
          record_activity(ActivityEvent::ACTION_READ, conversations: affected)
        when "mark_unread"
          Conversation.update_all_in_order(conversations, read: false)
          refresh_mobile_badge
        when "open"
          # Threads coming back OUT of spam are false positives — train ham on them
          # (the snapshot still holds the pre-update status).
          released = affected.select { |c| c.status == Conversation::STATUS_SPAM }
          Conversation.update_all_in_order(conversations, status: Conversation::STATUS_OPEN)
          # Restored threads re-enter the unread pool.
          refresh_mobile_badge
          SpamFeedbackJob.perform_later(released.map(&:id), false) if released.any?
        when LoreMemberDone::ACTION_DONE
          # Only personal-bucket threads; a work item is an archive for the team. The
          # others are left out of `updated`, so a client that raced a re-triage re-fetches.
          personal = affected.select { |c| TriageLabel::PERSONAL.include?(c.triage_label) }
          LoreMemberDone.mark!(personal, current_active_membership!)
          return render json: { updated: personal.length }
        when LoreMemberDone::ACTION_UNDONE
          LoreMemberDone.where(conversation_id: affected.map(&:id), membership: current_active_membership!).delete_all
        when "delete"
          # Permanent, and only for threads already in trash/spam: the same rule as
          # #empty, one thread at a time. Anything else is left alone and not
          # counted, so a client can't purge live team mail in one call.
          doomed = affected.select { |c| Conversation::EMPTYABLE_STATUSES.include?(c.status) }
          Conversation.where(id: doomed.map(&:id)).destroy_all
          clear_mobile_notifications(doomed.map(&:key)) if doomed.any?
          return render json: { updated: doomed.length }
        else
          return render json: ErrorSerializer.serialize("Unknown action: #{action}", status: 422), status: :unprocessable_content
        end

        render json: { updated: affected_keys.length }
      end

      # Permanently wipe a whole disposable folder ("Empty Trash" / "Empty Spam").
      # Irreversible: the threads and their messages are destroyed, not restatused.
      # Only trash/spam are emptyable — archived mail is kept, never bulk-purged.
      def empty
        status = params[:status].to_s
        unless Conversation::EMPTYABLE_STATUSES.include?(status)
          return render json: ErrorSerializer.serialize("Folder cannot be emptied: #{status.presence || 'missing'}", status: 422), status: :unprocessable_content
        end

        scope = visible_conversations.where(status: status)
        total = scope.count
        # A big folder is destroyed in batches off the request: destroy_all with
        # callbacks over thousands of threads is a minutes-long request and a
        # held transaction. Small folders still finish before the response.
        if total > EMPTY_FOLDER_SYNC_LIMIT
          EmptyFolderJob.perform_later(current_organization.id, current_membership&.id, status)
          return render json: { deleted: total, async: true }
        end

        affected_keys = scope.pluck(:key)
        scope.destroy_all
        clear_mobile_notifications(affected_keys) if affected_keys.any?

        render json: { deleted: affected_keys.length }
      end

      # Unread count for the org's open pool — drives the mobile app-icon badge
      # and the web/desktop tab badges (the domain/MX half; the client adds its
      # offline-channel unread). Open + unread only: snoozed (pending) and hidden
      # (trash/spam/archived) threads are not in the inbox, so they don't count.
      #
      # Takes the same ?domain=/?space= narrowing as #index so a per-domain
      # workspace tab counts its own pool. This is the ONLY correct source for a
      # badge: counting unread rows out of a page of #index caps the number at
      # the page size (the web badge silently topped out at 25 for a year).
      def unread_count
        count = filter_by_folder(filter_by_space_and_domain(visible_conversations))
          .where(status: Conversation::STATUS_OPEN, read: false)
          .count
        render json: { unread_count: count }
      end

      # spec 4.2.6, A6.5
      def archive
        conversation = visible_conversations.find_by!(key: params[:id])
        conversation.update!(status: Conversation::STATUS_ARCHIVED)
        clear_mobile_notifications(conversation.key)
        record_activity(ActivityEvent::ACTION_ARCHIVED, conversation: conversation)
        render json: { conversation: ConversationSerializer.new(conversation).to_h }
      end

      # spec 4.2.6, A6.5
      def trash
        conversation = visible_conversations.find_by!(key: params[:id])
        conversation.update!(status: Conversation::STATUS_TRASH)
        clear_mobile_notifications(conversation.key)
        record_activity(ActivityEvent::ACTION_DELETED, conversation: conversation)
        render json: { conversation: ConversationSerializer.new(conversation).to_h }
      end

      # spec 11.1.3, A6.5
      def spam
        conversation = visible_conversations.find_by!(key: params[:id])
        conversation.update!(status: Conversation::STATUS_SPAM)
        clear_mobile_notifications(conversation.key)
        record_spam_feedback(conversation, true)
        render json: { conversation: ConversationSerializer.new(conversation).to_h }
      end

      # spec 11.1.3, A15.2
      def spam_feedback
        conversation = visible_conversations.find_by!(key: params[:id])
        is_spam = params[:is_spam] != false && params[:is_spam] != "false"

        if is_spam
          conversation.update!(status: Conversation::STATUS_SPAM)
          clear_mobile_notifications(conversation.key)
        elsif conversation.status == Conversation::STATUS_SPAM
          conversation.update!(status: Conversation::STATUS_OPEN)
          # False positive released back to the inbox — run the triage that spam
          # skipped at ingest. Sealed threads can't re-triage server-side (the
          # transient excerpt is long gone); their label comes from the client.
          latest = conversation.messages.where(is_inbound: true).order(created_at: :desc).first
          if latest && !latest.sealed? && conversation.triage_label.nil? &&
             conversation.organization.ai_triage_enabled? && SpaceClassifier.enabled?
            ClassifySpaceJob.perform_later(conversation.id)
          end
        end

        # Train Rspamd on user feedback (spec 11.1.3)
        record_spam_feedback(conversation, is_spam)

        render json: { conversation: ConversationSerializer.new(conversation.reload).to_h }
      end

      # spec 4.1.5, A6.10
      def raw
        conversation = visible_conversations.find_by!(key: params[:id])
        message = conversation.messages.readable_by(current_membership).find_by!(key: params[:message_id])

        render json: {
          message_id: message.key,
          message_id_header: message.message_id_header,
          in_reply_to: message.in_reply_to,
          references: message.references_header,
          from: message.from_address,
          to: message.to_address,
          cc: message.cc_address,
          subject: message.subject,
          body_plain: message.body_plain,
          body_html: message.body_html,
          content_type: message.content_type,
          created_at: message.created_at
        }
      end

      # spec 4.2.7, A6.6 — Snooze
      def snooze
        conversation = visible_conversations.find_by!(key: params[:id])
        snoozed_until = Time.zone.parse(params[:until].to_s)
        if snoozed_until.nil?
          return render json: ErrorSerializer.serialize("invalid until", status: 422), status: :unprocessable_content
        end
        conversation.update!(status: Conversation::STATUS_PENDING, snoozed_until: snoozed_until)
        clear_mobile_notifications(conversation.key)
        record_activity(ActivityEvent::ACTION_SNOOZED, conversation: conversation, metadata: { until: params[:until] })
        render json: { conversation: ConversationSerializer.new(conversation).to_h }
      rescue ArgumentError
        render json: ErrorSerializer.serialize("invalid until", status: 422), status: :unprocessable_content
      end

      def unsnooze
        conversation = visible_conversations.find_by!(key: params[:id])
        conversation.update!(status: Conversation::STATUS_OPEN, snoozed_until: nil)
        refresh_mobile_badge # back in the inbox, back in the unread count
        render json: { conversation: ConversationSerializer.new(conversation).to_h }
      end

      # spec 4.2.8, A6.7 — Merge
      def merge
        conversation = visible_conversations.find_by!(key: params[:id])
        target = visible_conversations.find_by!(key: params[:target_id])

        conversation.messages.update_all(conversation_id: target.id)
        conversation.notes.update_all(conversation_id: target.id)
        target.refresh_sent_only!
        merged_key = conversation.key
        conversation.destroy!
        clear_mobile_notifications(merged_key)

        ActivityEvent.log(conversation: target, action: "merged", metadata: { merged_from: params[:id] })
        render json: { conversation: ConversationDetailSerializer.new(target.reload).to_h }
      end

      # spec 4.2.8, A6.8 — Split
      def split
        conversation = visible_conversations.find_by!(key: params[:id])
        message = conversation.messages.readable_by(current_membership).find_by!(key: params[:message_id])

        new_conv = visible_conversations.create!(
          subject: message.subject || conversation.subject,
          from_address: message.from_address,
          to_address: message.to_address,
          status: Conversation::STATUS_OPEN,
          snippet: SnippetBuilder.build(message.body_plain, message.body_html)
        )

        message.update!(conversation: new_conv)
        [conversation, new_conv].each(&:refresh_sent_only!)
        ActivityEvent.log(conversation: new_conv, action: "split_from", metadata: { original: params[:id] })

        render json: { conversation: ConversationSerializer.new(new_conv).to_h }, status: :created
      end

      private

      # iOS and Android send no status for their Inbox; web sends status=open.
      def inbox_listing?
        [nil, "", Conversation::STATUS_OPEN].include?(params[:status]) && NOT_INBOX_PARAMS.none? { |p| params[p].present? }
      end

      # Tell mobile devices to clear any delivered notification(s) for a
      # conversation that just left the inbox (trash/archive/spam/merge), so a
      # stale lockscreen banner doesn't linger after the user dealt with it on
      # another device. Best-effort: never let a push failure break the action.
      def clear_mobile_notifications(*conversation_keys)
        MobilePushSender.remove_for_org(current_organization, conversation_keys.flatten)
        # The thread also left (or entered) the unread pool. The removal push
        # carries a fresh badge, but it rides the throttled background lane, so
        # it can't be relied on to move the number — send the badge refresh too.
        refresh_mobile_badge
      rescue => e
        Rails.logger.warn("[ConversationsController] removal push error: #{e.message}")
      end

      # Unread moved without a thread leaving the inbox (mark read/unread, or a
      # restore out of spam/trash): no banner to clear, but every other device's
      # app-icon badge is now wrong. Enqueued, not inline — the fan-out walks
      # every org membership + device. Best-effort, like the removal push.
      def refresh_mobile_badge
        MobileBadgeRefreshJob.perform_later(current_organization.id)
      rescue => e
        Rails.logger.warn("[ConversationsController] badge push error: #{e.message}")
      end

      # Narrow a conversation scope by the two workspace axes both #index and
      # #unread_count take, so a list and its badge can't drift apart:
      #   ?space=spc_… — Spaces dashboard drill-in (one classification bucket)
      #   ?domain=dom_… — per-domain workspace tab (the conversation's domain_id
      #                   is set at inbound from the recipient domain)
      # An unknown key yields nothing rather than leaking the unfiltered pool.
      # Tenant-scoped already via visible_conversations.
      def filter_by_space_and_domain(scope)
        if params[:space].present?
          space = current_organization.spaces.find_by(key: params[:space])
          scope = space ? scope.where(space_id: space.id) : scope.none
        end

        if params[:domain].present?
          domain = current_organization.domains.find_by(key: params[:domain])
          scope = domain ? scope.where(domain_id: domain.id) : scope.none
        end

        scope
      end

      # ?folder= (AddressFolders): "inbox", an address local part ("info",
      # "waseem+receipts") or "other". With ?domain= it is that domain's folder;
      # "inbox" without one is the Inbox across every domain the member works on.
      # No ?folder= keeps the old listing (the whole pool), so clients opt in.
      def filter_by_folder(scope)
        folder = params[:folder].to_s.downcase
        return scope if folder.blank? || current_membership.nil?

        AddressFolders.across(current_membership, scope, folder, domain_key: params[:domain])
      end

      # Scope conversations by assignee: "me" → assigned to the caller; "none"/
      # "unassigned" → no assignee; otherwise a specific membership key.
      def filter_by_assignee(scope, assignee)
        if %w[none unassigned].include?(assignee)
          return scope.where.missing(:conversation_assignees)
        end

        membership = if assignee == "me"
          current_organization.memberships.find_by(user: current_user)
        else
          current_organization.memberships.find_by(key: assignee)
        end
        return scope.none unless membership

        scope.joins(:conversation_assignees)
          .where(conversation_assignees: { membership_id: membership.id })
          .distinct
      end

      def conversation_update_params
        params.permit(:status, :read)
      end

      # Spam feedback has two halves: teach Bayes, and remember the sender.
      # Bayes alone is useless here — it needs 50 learns per class before
      # BAYES_* scores anything, so on normal volume "mark as spam" did nothing
      # to the NEXT mail from that sender and it kept landing in the inbox.
      # Both halves run in SpamFeedbackJob: training blocks on an HTTP round
      # trip to Rspamd, which doesn't belong in-request.
      def record_spam_feedback(conversation, is_spam)
        SpamFeedbackJob.perform_later([ conversation.id ], is_spam)
      end
    end
  end
end
