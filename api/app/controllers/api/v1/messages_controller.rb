module Api
  module V1
    class MessagesController < BaseController
      include ClientMessageId
      include RecordsActivity
      before_action :require_organization!

      # spec 4.2.1, 8.1.2, A7.1
      def create
        # Idempotent retry (a queued client resending after a lost response): the
        # client names the Message-ID up front, and a send that already exists
        # under it is answered, not repeated.
        if (mid = client_message_id) && (existing = current_organization.messages.find_by(message_id_header: mid))
          return render_existing_send(existing)
        end

        from = message_params[:from_address]
        return refuse_sender(from) if from.present? && !sendable_from?(from)
        return refuse_size if too_big?(attachable.where(key: Array(params[:attachment_keys])))

        # Reputation throttle for our own SMTP (docs/Mail-Deliverability.md):
        # young orgs get tight hourly/daily caps; 6-month-old orgs are
        # unlimited. Checked before any row is written.
        rcpts = SendQuota.count_recipients(message_params[:to_address], message_params[:cc_address], message_params[:bcc_address])
        if (quota_error = SendQuota.new(current_organization).deny_reason(recipients: rcpts))
          return render json: ErrorSerializer.serialize(quota_error, status: 429), status: :too_many_requests
        end

        # Resolve the sealing decision FIRST: a sealed thread must never get a
        # plaintext conversation preview either (docs/E2EE.md Phase I — caught
        # by the Phase-H leak audit).
        sealing_domain = OutboundMessageSealer.sealing_domain(current_organization, message_params[:from_address])

        conversation = if params[:conversation_id].present?
          visible_conversations.find_by!(key: params[:conversation_id])
        elsif sealing_domain
          visible_conversations.create!(
            subject: nil,
            subject_hmac: E2ee.subject_threading_hmac(message_params[:subject]),
            from_address: nil,
            to_address: nil,
            status: Conversation::STATUS_OPEN,
            domain: sender_domain(message_params[:from_address]),
            personal_membership_id: current_organization.personal_membership_id_for_thread(message_params[:from_address], message_params[:to_address])
          )
        else
          # New conversation
          visible_conversations.create!(
            subject: message_params[:subject],
            from_address: message_params[:from_address],
            to_address: message_params[:to_address],
            status: Conversation::STATUS_OPEN,
            domain: sender_domain(message_params[:from_address]),
            personal_membership_id: current_organization.personal_membership_id_for_thread(message_params[:from_address], message_params[:to_address])
          )
        end

        message = conversation.messages.build(
          organization: current_organization,
          from_address: message_params[:from_address],
          to_address: message_params[:to_address],
          cc_address: message_params[:cc_address],
          bcc_address: message_params[:bcc_address],
          subject: message_params[:subject] || conversation.subject,
          body_plain: message_params[:body_plain],
          body_html: message_params[:body_html],
          content_type: message_params[:content_type] || "text/plain",
          is_inbound: false,
          is_draft: false,
          sender_membership_id: current_membership&.id
        )
        thread_reply(message, conversation) if params[:conversation_id].present?
        message.message_id_header = client_message_id if client_message_id

        # E2EE domains (docs/E2EE.md Phase I): compose the wire MIME while the
        # plaintext is still only in this request's RAM, then seal BOTH copies —
        # the queued MIME to the MTA delivery key and the at-rest row to the
        # domain key — before anything durable is written.
        if sealing_domain
          message.message_id_header ||= "<#{SecureRandom.uuid}@#{sealing_domain.name}>"
          sealer = OutboundMessageSealer.new(message, sealing_domain)
          mime = OutboundMailPublisher.new(message, attachments: pending_attachments).compose_mime
          sealer.seal_mime!(mime)
          sealer.seal_row!
        end

        # A compose draft's private thread goes shared with the send, or not at all.
        saved = Conversation.transaction do
          conversation.publish_draft_thread!
          message.save || raise(ActiveRecord::Rollback)
          # Whoever starts a thread keeps it, even one stamped as a teammate's
          # personal mail (shared From → their address): the same grant a
          # compose draft's author holds, so they can see and undo what they sent.
          if current_membership && conversation.personal_membership_id && conversation.personal_membership_id != current_membership.id
            ConversationAccess.find_or_create_by!(conversation: conversation, membership: current_membership)
          end
          true
        end
        if saved
          # Link pre-uploaded attachments to this message
          link_attachments(message)

          # Sealed threads keep no plaintext preview (docs/E2EE.md).
          conversation.update!(snippet: SnippetBuilder.build(message.body_plain, message.body_html)) unless message.sealed?
          # The owner spoke last: the thread now waits on the other side. A rule,
          # not a Jev call; the next inbound message re-triages it (docs/Triage.md).
          conversation.update!(triage_label: TriageLabel::WAITING_REPLY, triage_source: TriageLabel::SOURCE_RULE_SENT)

          # Hand off to the outbound pipeline (NATS → Go SMTP sender). Deferred by
          # the undo-send window so a cancel-send can intercept it (the job skips
          # drafts); async so a NATS hiccup doesn't fail the request.
          OutboundDeliveryJob.set(wait: Message::SEND_UNDO_WINDOW).perform_later(message.id)

          # Attribute a reply to the sender for the Team activity board — only when
          # it answers an existing thread (a brand-new outbound isn't a "reply").
          record_activity(ActivityEvent::ACTION_REPLIED, conversation: conversation) if params[:conversation_id].present?

          Rails.logger.info("[MessagesController] Created outbound message #{message.key} from=#{message.from_address} to=#{message.to_address} attachments=#{message.attachments.count}")
          render json: { message: MessageSerializer.new(message).to_h }, status: :created
        else
          Rails.logger.warn("[MessagesController] Message validation failed: #{message.errors.full_messages.join(', ')}")
          render json: ErrorSerializer.serialize(message.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # spec 8.1.8, A7.5 — Schedule send for later
      def schedule
        draft = Message.where(conversation: visible_conversations, is_draft: true, owner_membership_id: current_membership&.id)
          .find_by!(key: params[:id])
        return refuse_size if too_big?(draft.attachments)

        # A sealed draft (E2EE domain) has no plaintext to compose wire MIME
        # from at fire time, and no pre-sealed MIME either — send it directly
        # instead (docs/E2EE.md Phase I; client-supplied plaintext scheduling
        # is the follow-on).
        if draft.sealed? && draft.sealed_mime.blank?
          return render json: ErrorSerializer.serialize(
            "Scheduled send is not yet available for end-to-end encrypted drafts — send it directly",
            status: 422
          ), status: :unprocessable_content
        end

        send_at = Time.parse(params[:send_at])

        if send_at <= Time.current
          return render json: ErrorSerializer.serialize("send_at must be in the future", status: 422), status: :unprocessable_content
        end

        # Same reputation throttle as an immediate send — checked at schedule
        # time (the acceptance point; sealed drafts count as one recipient).
        rcpts = SendQuota.count_recipients(draft.to_address, draft.cc_address, draft.bcc_address)
        if (quota_error = SendQuota.new(current_organization).deny_reason(recipients: rcpts))
          return render json: ErrorSerializer.serialize(quota_error, status: 429), status: :too_many_requests
        end

        # Promote the draft to a real outbound message that delivers at send_at: the
        # delivery job is enqueued with wait_until and skips drafts, so a later
        # cancel-send (which reverts to draft) still intercepts it.
        Conversation.transaction do
          draft.conversation.publish_draft_thread!
          draft.update!(is_draft: false, scheduled_at: send_at, owner_membership_id: draft.conversation.owner_membership_id,
                        sender_membership_id: current_membership&.id)
        end
        OutboundDeliveryJob.set(wait_until: send_at).perform_later(draft.id)

        render json: { message: MessageSerializer.new(draft).to_h, scheduled_at: send_at.iso8601 }
      rescue ArgumentError
        render json: ErrorSerializer.serialize("invalid send_at", status: 422), status: :unprocessable_content
      end

      # spec 8.1.9, A7.6 — Undo send (within cancellation window)
      def cancel_send
        # Only a sent outbound message, and only by its recorded sender
        # (sender_membership_id, 2026-10-24); unattributed mail can't be undone.
        message = Message.where(conversation: visible_conversations, is_inbound: false, is_draft: false).find_by!(key: params[:id])
        unless current_membership && message.sender_membership_id == current_membership.id
          return render json: ErrorSerializer.serialize("Only the sender can undo this send", status: 403), status: :forbidden
        end

        # Cancellable while undeliverable: within the undo window, or any time before
        # a future scheduled send fires. Flipping is_draft makes the deferred/awaiting
        # OutboundDeliveryJob skip it, so it never goes out.
        scheduled_future = message.scheduled_at.present? && message.scheduled_at > Time.current
        if scheduled_future || message.created_at > Message::SEND_UNDO_WINDOW.ago
          # Back to a draft: the canceller's alone (sent mail records no author),
          # and a thread left with nothing sent is private to them again.
          Conversation.transaction do
            message.update!(is_draft: true, scheduled_at: nil, owner_membership_id: current_membership&.id || message.owner_membership_id)
            message.conversation.privatize_draft_thread!(current_membership)
          end
          render json: { message: MessageSerializer.new(message).to_h, cancelled: true }
        else
          render json: ErrorSerializer.serialize("Cancellation window has passed", status: 422), status: :unprocessable_content
        end
      end

      # RSVP to an emailed meeting invite (docs/Meeting-Invites.md). Records the
      # user's response on the message and emails a METHOD:REPLY back to the
      # organizer so their calendar client updates. MX-only: local channels RSVP
      # through the Rust core, not this endpoint.
      def rsvp
        status = params[:status].to_s
        unless Message::RSVP_RESPONSES.include?(status)
          return render json: ErrorSerializer.serialize("invalid RSVP status", status: 422), status: :unprocessable_content
        end

        # Scope through visible_conversations so a domain-scoped member can't
        # answer another domain's invite (E3).
        message = Message.where(conversation: visible_conversations).readable_by(current_membership).find_by!(key: params[:id])
        invite = message.calendar_invite
        if invite.blank?
          return render json: ErrorSerializer.serialize("message is not an invite", status: 422), status: :unprocessable_content
        end

        message.update!(rsvp_status: status)
        send_calendar_reply(message, invite, status)
        # Answering the organizer and having the meeting show up in your own
        # week are two different things — accepting now also places it on the
        # member's calendar (docs/Calendar.md). Declining removes any copy.
        event = CalendarInviteImport.apply(current_organization, current_active_membership!, invite, status)

        ActionCable.server.broadcast(
          "organization_#{current_organization.key}",
          { type: "message_rsvp", message_id: message.key, rsvp_status: status }
        )
        if event
          ActionCable.server.broadcast(
            "calendar_#{current_organization.key}",
            { type: "event_created", event_id: event.key }
          )
        end
        render json: { message: MessageSerializer.new(message).to_h }
      end

      # Put an emailed event straight onto the member's calendar
      # (docs/Meeting-Invites.md) — the "Add to calendar" action for a PUBLISH ICS,
      # which is a confirmation rather than an invitation. No REPLY is emailed:
      # nobody asked for an answer.
      #
      # Idempotent through CalendarInviteImport, which upserts on the invite's UID,
      # so tapping twice (or a re-sent confirmation) updates the one event.
      def calendar_import
        # Scope through visible_conversations so a domain-scoped member can't import
        # another domain's event (E3).
        message = Message.where(conversation: visible_conversations).readable_by(current_membership).find_by!(key: params[:id])
        invite = message.calendar_invite
        # A detected meeting's times are the sender's wall clock: read them in the
        # viewer's zone (`time_zone`, IANA), else the org's.
        if invite.blank? && message.detected_meeting.present?
          invite = MeetingDetector.zoned_invite(message, params[:time_zone], current_organization)
        end
        if invite.blank?
          return render json: ErrorSerializer.serialize("message carries no event", status: 422),
                        status: :unprocessable_content
        end

        event = CalendarInviteImport.apply(
          current_organization, current_active_membership!, invite, CalendarAttendee::RESPONSE_ACCEPTED
        )
        if event.nil?
          return render json: ErrorSerializer.serialize("event could not be imported", status: 422),
                        status: :unprocessable_content
        end

        ActionCable.server.broadcast(
          "calendar_#{current_organization.key}",
          { type: "event_created", event_id: event.key }
        )
        render json: { event: CalendarEventSerializer.new(event).to_h }
      end

      private

      # Emails a calendar REPLY to the organizer, threaded onto the invite. The
      # address that received the invite is the attendee replying.
      def send_calendar_reply(invite_msg, invite, status)
        organizer = invite["organizer_email"].presence
        return if organizer.blank?

        attendee = invite_msg.to_address.to_s[/[\w.+-]+@[\w.-]+/] || invite_msg.to_address
        summary = invite["summary"].presence || "invitation"
        prefix = status.capitalize

        reply = invite_msg.conversation.messages.create!(
          organization: current_organization,
          from_address: attendee,
          to_address: organizer,
          subject: "#{prefix}: #{summary}",
          body_plain: "#{prefix} the invitation “#{summary}”.",
          content_type: "text/plain",
          in_reply_to: invite_msg.message_id_header,
          references_header: [invite_msg.references_header, invite_msg.message_id_header].compact.join(" ").presence,
          calendar_reply: IcsReply.build(invite, attendee, status),
          is_inbound: false,
          is_draft: false
        )
        OutboundDeliveryJob.perform_later(reply.id)
      end

      def render_existing_send(existing)
        mine = Message.where(conversation: visible_conversations, is_draft: false, is_inbound: false).exists?(existing.id)
        if mine
          # The first attempt may have died between saving the row and enqueueing
          # its delivery. The job skips what already reached the queue, so
          # enqueueing it again is safe and closes that gap.
          OutboundDeliveryJob.set(wait: Message::SEND_UNDO_WINDOW).perform_later(existing.id)
          return render json: { message: MessageSerializer.new(existing).to_h }
        end

        render json: ErrorSerializer.serialize("Message-ID already in use", status: 409), status: :conflict
      end

      # A reply carries RFC 5322 In-Reply-To/References so the recipient's client
      # threads it (the publisher only writes them when set). The parent is the
      # message the client names (`reply_to_message_id`), else the thread's
      # latest sent or received message.
      def thread_reply(message, conversation)
        sent = conversation.messages.where(is_draft: false).where.not(message_id_header: [nil, ""])
        parent = sent.find_by(key: params[:reply_to_message_id]) if params[:reply_to_message_id].present?
        parent ||= sent.order(:created_at).last
        return unless parent

        message.in_reply_to = parent.message_id_header
        message.references_header = [parent.references_header, parent.message_id_header].compact_blank.join(" ")
      end

      def message_params
        params.permit(:conversation_id, :from_address, :to_address, :cc_address, :bcc_address,
                       :subject, :body_plain, :body_html, :content_type)
      end

      # The pre-uploaded attachment rows named by the request, resolved BEFORE
      # the message is saved (the sealing flow composes MIME pre-save, when
      # nothing is linked yet).
      def pending_attachments
        Array(params[:attachment_keys]).filter_map do |att_key|
          attachable.find_by(key: att_key)
        end
      end

      # Attachments this member may move onto their message: only uploads on
      # their own drafts (every client uploads to the draft, then sends its
      # keys). Linking moves the row, so a key from received or sent mail, a
      # colleague's draft or another domain's thread must never match.
      def attachable
        current_organization.attachments.joins(:message)
          .where(messages: { is_draft: true, owner_membership_id: current_membership.id,
                             conversation_id: visible_conversations.select(:id) })
      end

      # Re-associate pre-uploaded attachments (by key) to the outbound message
      def too_big?(attachments) = attachments.sum(:size_bytes) > OutboundMailPublisher::MAX_ATTACHMENT_BYTES

      def refuse_size
        mb = OutboundMailPublisher::MAX_ATTACHMENT_BYTES / 1024 / 1024
        render json: ErrorSerializer.serialize("Attachments add up to more than #{mb} MB; most mail servers refuse that. " \
                                               "Share large files as a Disk link instead.", status: 413),
               status: :content_too_large
      end

      def link_attachments(message)
        keys = params[:attachment_keys]
        return if keys.blank?

        keys.each do |att_key|
          attachment = attachable.find_by(key: att_key)
          if attachment
            attachment.update!(message: message)
            Rails.logger.info("[MessagesController] Linked attachment #{att_key} (#{attachment.filename}) to message #{message.key}")
          else
            Rails.logger.warn("[MessagesController] Attachment #{att_key} not found, skipping")
          end
        end
      end
    end
  end
end
