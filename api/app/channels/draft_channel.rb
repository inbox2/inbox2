# spec 5.4.4, 8.1.11 — Collaborative drafting via Action Cable
# Broadcasts cursor positions and content updates to all editors of a shared draft.
class DraftChannel < ApplicationCable::Channel
  def subscribed
    @draft = find_draft
    if @draft
      stream_for @draft
      broadcast_editor_joined
    else
      reject
    end
  end

  def update_content(data)
    @draft = find_draft or raise ActiveRecord::RecordNotFound
    DraftChannel.broadcast_to(@draft, {
      type: "content_update",
      user_id: current_user.key,
      username: current_user.username,
      body: data["body"],
      version: data["version"],
      timestamp: Time.current.iso8601
    })
  end

  def update_cursor(data)
    @draft = find_draft or raise ActiveRecord::RecordNotFound
    DraftChannel.broadcast_to(@draft, {
      type: "cursor_update",
      user_id: current_user.key,
      username: current_user.username,
      position: data["position"],
      selection: data["selection"],
      timestamp: Time.current.iso8601
    })
  end

  # Relay Yjs binary update (base64 encoded) to all subscribers
  def sync_update(data)
    @draft = find_draft or raise ActiveRecord::RecordNotFound
    DraftChannel.broadcast_to(@draft, {
      type: "yjs_update",
      user_id: current_user.key,
      update: data["update"],
      timestamp: Time.current.iso8601
    })
  end

  # Relay Yjs awareness update (cursor positions, user presence)
  def sync_awareness(data)
    @draft = find_draft or raise ActiveRecord::RecordNotFound
    DraftChannel.broadcast_to(@draft, {
      type: "yjs_awareness",
      user_id: current_user.key,
      update: data["update"],
      timestamp: Time.current.iso8601
    })
  end

  def unsubscribed
    if @draft
      DraftChannel.broadcast_to(@draft, {
        type: "editor_left",
        user_id: current_user.key,
        username: current_user.username,
        timestamp: Time.current.iso8601
      })
    end
  end

  private

  # Only the user's own draft, on a thread they may see (tenant + visibility
  # scoped): a draft is its author's alone (2026-10-24).
  def find_draft
    draft = Message.find_by(key: params[:draft_id], is_draft: true)
    return unless draft && visible_conversation(draft.conversation.key)

    draft if current_user.memberships.active.exists?(id: draft.owner_membership_id)
  end

  def broadcast_editor_joined
    DraftChannel.broadcast_to(@draft, {
      type: "editor_joined",
      user_id: current_user.key,
      username: current_user.username,
      timestamp: Time.current.iso8601
    })
  end
end
