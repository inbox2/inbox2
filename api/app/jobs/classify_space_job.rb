# Off-the-ingest-hot-path Jev triage for an MX conversation (docs/Triage.md):
# label + priority on every new inbound message, a Space while the thread has
# none, and — for a new thread — the OpenAI summary plus the deferred mobile push.
#
# `new_thread` = the first inbound message of the thread (or a thread released
# from spam): InboundMailProcessor skipped the inline push for it, so this job
# owns the alert. Re-triage of a later message (`new_thread` false) never pushes.
class ClassifySpaceJob < ApplicationJob
  queue_as :default
  discard_on ActiveJob::DeserializationError

  # 429/529/5xx/timeouts. Once the retries run out, park a still-unrouted thread
  # in the holding pen and send the push anyway — an alert must never be lost to
  # a Jev outage.
  retry_on Jev::Client::TransientError, wait: :polynomially_longer, attempts: 4 do |job, error|
    Rails.logger.warn("[ClassifySpaceJob] giving up on triage: #{error.message}")
    job.give_up
  end

  # `retriage` = LoreRetriageJob's one-time upgrade pass: triage fields only
  # (no summary, meeting detection, auto mode or push).
  def perform(conversation_id, new_thread = true, retriage = false)
    conversation = Conversation.find_by(id: conversation_id)
    return unless conversation

    triage(conversation, new_thread && !retriage, retriage)
    notify(conversation) if new_thread && !retriage
  end

  def give_up
    conversation_id, new_thread, retriage = arguments
    conversation = Conversation.find_by(id: conversation_id)
    return unless conversation

    SpaceClassifier.new(conversation.organization).file_in_holding_pen(conversation)
    notify(conversation) unless new_thread == false || retriage
  end

  private

  # No-ops when the thread is spam/trashed/archived (Rspamd or the user already
  # decided) or the org is no longer on a plan with AI triage (a downgrade
  # between enqueue and run).
  def triage(conversation, new_thread, retriage = false)
    return if Conversation::INBOX_HIDDEN_STATUSES.include?(conversation.status)

    org = conversation.organization
    return unless org.ai_triage_enabled?

    message = latest_inbound(conversation)
    breaker = self.class.breaker_for(org, conversation, message)
    SpaceClassifier.new(org, breaker: breaker).classify(conversation, message, new_thread: new_thread,
                                                                    retriage: retriage)
  end

  # Deferred new-message alert, only while the thread is still an open inbox
  # item: skips spam (Rspamd's verdict at ingest) and a thread the user
  # archived/trashed in the seconds before this job ran. See docs/Cloud-Push.md.
  def notify(conversation)
    message = latest_inbound(conversation)
    return unless message && conversation.reload.status == Conversation::STATUS_OPEN

    MobilePushSender.notify_new_message(conversation.organization, conversation, message)
  end

  def latest_inbound(conversation) = self.class.latest_inbound(conversation)

  def self.latest_inbound(conversation)
    conversation.messages.where(is_inbound: true).order(created_at: :desc).first
  end

  # The breaker with the recipient domain + mailbox owner sub-caps (also used
  # by `lore:titles`).
  def self.breaker_for(org, conversation, message)
    domain, membership = triage_attribution(org, conversation, message)
    TriageBreaker.new(org, domain: domain, membership: membership)
  end

  # Resolve the recipient domain + mailbox owner for the breaker's sub-caps.
  # Best-effort: an unrecognised host or a shared/space alias (no mailbox) just
  # leaves that scope nil, so only the org (and domain, if known) caps apply.
  def self.triage_attribution(org, conversation, message)
    raw = message&.to_address.presence || conversation.to_address
    return [nil, nil] if raw.blank?

    addr = MailHeaderEncoding.bare_addresses(raw).first
    local, _, host = addr.to_s.rpartition("@")
    return [nil, nil] if host.blank?

    # Domain/Mailbox lowercase their names on write, so plain (indexed) equality
    # on the downcased input matches.
    domain = org.domains.find_by(name: host.downcase)
    return [domain, nil] if domain.nil? || local.blank?

    membership = domain.mailboxes.find_by(local_part: local.downcase)&.membership
    [domain, membership]
  end
end
