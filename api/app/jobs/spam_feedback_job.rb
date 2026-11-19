# Spam feedback off the request path. Two halves per conversation, moved here
# from ConversationsController because training is an HTTP round trip to Rspamd
# that "mark as spam" used to pay inline (per conversation, on the bulk path):
# teach Bayes, and junk-list/un-junk the sender. Takes the whole id list so a
# bulk action costs one enqueue.
class SpamFeedbackJob < ApplicationJob
  queue_as :default
  discard_on ActiveJob::DeserializationError

  def perform(conversation_ids, is_spam)
    Conversation.where(id: conversation_ids).find_each do |conversation|
      train_rspamd(conversation, is_spam)
      update_junk_filter(conversation, is_spam)
    end
  end

  private

  # Junk-list the sender so inbound files their future mail into Spam;
  # releasing the thread back to the inbox un-lists them again.
  def update_junk_filter(conversation, is_spam)
    organization = conversation.organization
    address = latest_inbound_message(conversation)&.from_address&.downcase
    return if address.blank?
    # Never junk our own domains — one misclick would hide internal mail
    # org-wide (mail filters are org-scoped, like the pool itself).
    return if organization.domains.exists?(name: address.split("@").last)

    existing = organization.mail_filters.find_by(value: address)
    if is_spam
      # A value is unique per org across kinds: an explicit block/allow
      # entry is the user's own decision and outranks this.
      organization.mail_filters.create!(kind: MailFilter::KIND_JUNK, value: address) unless existing
    elsif existing&.kind == MailFilter::KIND_JUNK
      existing.destroy!
    end
  rescue => e
    Rails.logger.warn("[SpamFeedbackJob] Junk filter update failed: #{e.message}")
  end

  def latest_inbound_message(conversation)
    conversation.messages.where(is_inbound: true).order(created_at: :desc).first
  end

  def train_rspamd(conversation, is_spam)
    # Find the latest inbound message to train on
    message = latest_inbound_message(conversation)
    return unless message
    # Sealed rows have no plaintext to train on (every header/body field is
    # nil), and decrypted content must never come back to the server after
    # the ingest window — Bayes just doesn't learn from sealed feedback.
    return if message.sealed?

    # Reconstruct raw message for training (body_plain fallback if no raw stored)
    raw = compose_training_message(message)
    return if raw.blank?

    client = RspamdClient.new
    if is_spam
      client.train_spam(raw)
    else
      client.train_ham(raw)
    end
  rescue => e
    Rails.logger.warn("[SpamFeedbackJob] Rspamd training error: #{e.message}")
  end

  def compose_training_message(message)
    lines = []
    lines << "From: #{message.from_address}"
    lines << "To: #{message.to_address}"
    lines << "Subject: #{message.subject}" if message.subject.present?
    lines << "Message-ID: #{message.message_id_header}" if message.message_id_header.present?
    lines << ""
    lines << (message.body_plain.presence || message.body_html.presence || "")
    lines.join("\r\n")
  end
end
