# spec 5.4.1, 5.4.2, A12.3 — Collision detection & presence
# Delivered via Action Cable (spec 16.3.4)
class PresenceChannel < ApplicationCable::Channel
  def subscribed
    conversation = visible_conversation(params[:conversation_id])
    return reject unless conversation

    stream_for conversation

    PresenceChannel.broadcast_to(conversation, {
      type: "presence",
      user_id: current_user.key,
      username: current_user.username,
      action: "viewing",
      timestamp: Time.current.iso8601
    })
  end

  def replying
    conversation = visible_conversation!(params[:conversation_id])
    PresenceChannel.broadcast_to(conversation, {
      type: "presence",
      user_id: current_user.key,
      username: current_user.username,
      action: "replying",
      timestamp: Time.current.iso8601
    })
  end

  def unsubscribed
    # Broadcast departure when user leaves
  end
end
