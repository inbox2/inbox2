module Api
  module V1
    class NotesController < BaseController
      before_action :require_organization!

      # spec 9.1.1, A12.1
      def create
        conversation = find_conversation
        note = conversation.notes.build(
          organization: current_organization,
          membership: current_active_membership!,
          body: note_params[:body],
          parent_note_id: resolve_parent_note_id(conversation)
        )

        if note.save
          render json: { note: NoteSerializer.new(note).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(note.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # spec 9.1.6, A12.2
      def update
        conversation = find_conversation
        note = conversation.notes.find_by!(key: params[:note_id])

        unless note.membership_id == current_active_membership!.id
          return render json: ErrorSerializer.serialize("Can only edit your own notes", status: 403), status: :forbidden
        end

        if note.update(body: note_params[:body])
          render json: { note: NoteSerializer.new(note).to_h }
        else
          render json: ErrorSerializer.serialize(note.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # spec 9.1.6, A12.2
      def destroy
        conversation = find_conversation
        note = conversation.notes.find_by!(key: params[:note_id])

        unless note.membership_id == current_active_membership!.id
          return render json: ErrorSerializer.serialize("Can only delete your own notes", status: 403), status: :forbidden
        end

        note.destroy!
        head :no_content
      end

      # spec 9.1.7 — Add reaction
      def add_reaction
        conversation = find_conversation
        note = conversation.notes.find_by!(key: params[:note_id])

        reaction = note.reactions.build(membership: current_active_membership!, emoji: params[:emoji])
        if reaction.save
          render json: { note: NoteSerializer.new(note.reload).to_h }
        else
          render json: ErrorSerializer.serialize(reaction.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # spec 9.1.7 — Remove reaction
      def remove_reaction
        conversation = find_conversation
        note = conversation.notes.find_by!(key: params[:note_id])

        reaction = note.reactions.find_by!(membership: current_active_membership!, emoji: params[:emoji])
        reaction.destroy!
        render json: { note: NoteSerializer.new(note.reload).to_h }
      end

      private

      def note_params
        params.permit(:body)
      end

      def find_conversation
        visible_conversations.find_by!(key: params[:id])
      end

      def resolve_parent_note_id(conversation)
        return nil unless params[:parent_note_id].present?

        parent = conversation.notes.find_by!(key: params[:parent_note_id])
        parent.id
      end
    end
  end
end
