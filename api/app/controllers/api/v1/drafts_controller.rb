module Api
  module V1
    class DraftsController < BaseController
      include ClientMessageId
      before_action :require_organization!

      # spec 8.1.5, A7.4
      def index
        # Scoped like every other read: a member sees drafts on threads in their
        # slice of the pool, never a colleague's private imported history or
        # another domain's threads (the org-wide form leaked both bodies), and
        # only their own drafts.
        drafts = own_drafts
          .includes(:conversation, :attachments).order(updated_at: :desc)
        render json: { drafts: drafts.map { |d| MessageSerializer.new(d).to_h } }
      end

      def create
        # Upsert by client Message-ID: a queued client saving a newer version of
        # the same draft (or retrying a lost response) replaces it whole. Every
        # field is taken as sent, so a version can clear a Cc or the HTML.
        if (mid = client_message_id) && (existing = current_organization.messages.find_by(message_id_header: mid))
          return replace_draft(existing)
        end

        from = draft_params[:from_address]
        return refuse_sender(from) if from.present? && !sendable_from?(from)

        # A draft on a sealed domain must not leave a plaintext conversation
        # preview either (docs/E2EE.md Phase I).
        sealing_domain = OutboundMessageSealer.sealing_domain(current_organization, draft_params[:from_address])

        # A new compose thread is the author's alone until it sends
        # (Conversation#publish_draft_thread!); an API key's stays shared.
        mine = current_membership ? { private: true, owner_membership_id: current_membership.id } : {}
        conversation = if params[:conversation_id].present?
          visible_conversations.find_by!(key: params[:conversation_id])
        elsif sealing_domain
          visible_conversations.create!(
            **mine,
            subject: nil,
            subject_hmac: E2ee.subject_threading_hmac(draft_params[:subject]),
            from_address: nil,
            to_address: nil,
            status: Conversation::STATUS_OPEN,
            domain: sender_domain(draft_params[:from_address]),
            personal_membership_id: current_organization.personal_membership_id_for_thread(draft_params[:from_address], draft_params[:to_address])
          )
        else
          visible_conversations.create!(
            **mine,
            subject: draft_params[:subject],
            from_address: draft_params[:from_address],
            to_address: draft_params[:to_address],
            status: Conversation::STATUS_OPEN,
            domain: sender_domain(draft_params[:from_address]),
            personal_membership_id: current_organization.personal_membership_id_for_thread(draft_params[:from_address], draft_params[:to_address])
          )
        end

        # Private threads are reached by grant (Conversation.visible_to), as imports are.
        ConversationAccess.find_or_create_by!(conversation: conversation, membership: current_membership) if conversation.private && current_membership

        draft = conversation.messages.build(
          organization: current_organization,
          owner_membership_id: current_membership&.id,
          from_address: draft_params[:from_address] || "",
          to_address: draft_params[:to_address],
          cc_address: draft_params[:cc_address],
          bcc_address: draft_params[:bcc_address],
          subject: draft_params[:subject],
          body_plain: draft_params[:body_plain],
          body_html: draft_params[:body_html],
          is_inbound: false,
          is_draft: true,
          message_id_header: client_message_id
        )

        seal_draft_if_needed(draft)

        if draft.save
          render json: { draft: MessageSerializer.new(draft).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(draft.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def update
        draft = own_drafts.find_by!(key: params[:id])
        from = draft_params[:from_address]
        return refuse_sender(from) if from.present? && !sendable_from?(from)

        # `replace`: the client sent the whole draft, so a blank field was cleared.
        fields = params[:replace].present? ? draft_params : draft_params.compact_blank
        draft.assign_attributes(fields.except(:conversation_id))
        seal_draft_if_needed(draft)

        if draft.save
          refile_thread(draft)
          render json: { draft: MessageSerializer.new(draft).to_h }
        else
          render json: ErrorSerializer.serialize(draft.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def destroy
        draft = own_drafts.find_by!(key: params[:id])
        conversation = draft.conversation
        draft.destroy!
        # A compose-draft spawns its own conversation (see #create); deleting the
        # last message must take the empty shell with it or it lingers as a
        # ghost row in every inbox.
        conversation.destroy! if conversation.messages.none?
        head :no_content
      end

      private

      def replace_draft(existing)
        draft = own_drafts.find_by(id: existing.id)
        unless draft
          # Sent since, or someone else's: never overwrite either.
          return render json: ErrorSerializer.serialize("Draft already sent or not yours", status: 409), status: :conflict
        end

        from = draft_params[:from_address]
        return refuse_sender(from) if from.present? && !sendable_from?(from)

        fields = %i[to_address cc_address bcc_address subject body_plain body_html]
        draft.assign_attributes(fields.index_with { |f| draft_params[f] })
        draft.from_address = from if from.present?
        seal_draft_if_needed(draft)
        if draft.save
          refile_thread(draft)
          render json: { draft: MessageSerializer.new(draft).to_h }
        else
          render json: ErrorSerializer.serialize(draft.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # Drafts of E2EE domains are sealed on every autosave (docs/E2EE.md
      # Phase I): the plaintext from the request transits RAM, the stored row
      # is ciphertext under the domain key.
      def seal_draft_if_needed(draft)
        domain = OutboundMessageSealer.sealing_domain(current_organization, draft.from_address)
        return unless domain

        draft.message_id_header ||= "<#{SecureRandom.uuid}@#{domain.name}>"
        OutboundMessageSealer.new(draft, domain).seal_row!
      end

      # A new thread whose only message is this draft follows its From to that
      # address's domain and personal owner, so switching From before sending
      # files it right.
      def refile_thread(draft)
        return unless (draft.saved_change_to_from_address? || draft.saved_change_to_to_address?) &&
                      draft.conversation.messages.count == 1

        domain = sender_domain(draft.from_address)
        draft.conversation.update!(domain: domain) if domain && domain.id != draft.conversation.domain_id
        draft.conversation.update!(
          personal_membership_id: current_organization.personal_membership_id_for_thread(draft.from_address, draft.to_address)
        )
      end

      def own_drafts
        Message.where(conversation: visible_conversations, is_draft: true, owner_membership_id: current_membership&.id)
      end

      def draft_params
        params.permit(:conversation_id, :from_address, :to_address, :cc_address, :bcc_address, :subject, :body_plain, :body_html)
      end
    end
  end
end
