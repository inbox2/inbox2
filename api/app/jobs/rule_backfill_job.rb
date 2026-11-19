# "Apply to existing emails" (spec 7.1.6 backfill). Runs one saved rule's actions
# over the org's already-received conversations, reusing RuleExecutor#apply_rule so
# matching + actions are identical to live inbound processing (tag/assign/grant are
# idempotent; webhook actions POST once per match).
#
# Bounded by MAX_CONVERSATIONS so a huge mailbox can't spawn an unbounded action
# storm; newest-first so the most relevant mail is covered when the cap is hit.
class RuleBackfillJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 200
  MAX_CONVERSATIONS = 5_000

  def perform(rule_id)
    rule = Rule.find_by(id: rule_id)
    return unless rule&.enabled?

    executor = RuleExecutor.new(rule.organization)
    scanned = 0
    matched = 0
    cursor = nil

    # Explicit newest-first paging: find_each would override the ORDER (it batches
    # by primary key), losing the "cover the most recent mail first" guarantee.
    # Keyset on (updated_at, id) rather than a growing OFFSET, which re-scans
    # every earlier page (quadratic over a 5k-thread backfill).
    loop do
      scope = rule.organization.conversations.not_private
                  .order(updated_at: :desc, id: :desc)
                  .limit(BATCH_SIZE)
                  .includes(messages: :attachments)
      scope = scope.where("(conversations.updated_at, conversations.id) < (?, ?)", *cursor) if cursor
      batch = scope.to_a
      break if batch.empty?

      batch.each do |conversation|
        message = conversation.messages.max_by { |m| [m.created_at, m.id] }
        next unless message

        scanned += 1
        matched += 1 if executor.apply_rule(rule, conversation, message)[:matched]
      end

      cursor = [batch.last.updated_at, batch.last.id]
      break if scanned >= MAX_CONVERSATIONS
    end

    Rails.logger.info(
      "[RuleBackfillJob] rule=#{rule.key} scanned=#{scanned} matched=#{matched}"
    )
  end
end
