# Executes routing rules against inbound conversations (spec 7.1.3, 7.3.12)
# Branching: if/else-if/else conditional chains (spec 7.3.12)
class RuleExecutor
  def initialize(organization)
    @organization = organization
  end

  def execute_for(conversation, message)
    @organization.rules.where(enabled: true).ordered.each do |rule|
      result = apply_rule(rule, conversation, message)
      break if result[:matched] && rule.stop_processing
    end
  end

  # Apply a single rule (with its branch/else chain) to one conversation/message,
  # running the matched actions. Returns { matched:, actions_taken: }. Public so the
  # backfill job ("apply to existing emails") reuses the exact same evaluation +
  # action semantics as live inbound processing — no divergent second matcher.
  def apply_rule(rule, conversation, message)
    preload_lookups(conversation)
    @target_cache = build_target_cache(conversation, message)
    @current_message = message
    @current_rule = rule

    taken = []
    matched = false

    if conditions_match?(rule.conditions, conversation, message)
      taken = apply_actions(rule.actions, conversation)
      matched = true
    elsif rule.branches.present?
      # First matching branch wins (mirrors the previous `any?` short-circuit).
      branch = rule.branches.find { |b| conditions_match?(b["conditions"] || [], conversation, message) }
      if branch
        taken = apply_actions(branch["actions"] || [], conversation)
        matched = true
      elsif rule.else_actions.present?
        taken = apply_actions(rule.else_actions, conversation)
      end
    elsif rule.else_actions.present?
      taken = apply_actions(rule.else_actions, conversation)
      matched = true
    end

    log_rule_run(rule, conversation, taken) if matched || taken.any?
    { matched: matched, actions_taken: taken }
  end

  # All conditions must hold (AND). An empty set never matches — a rule with no
  # conditions would fire on every message, which is never intended. Mirrors the
  # Rust core's `conditions_match`.
  def conditions_match?(conditions, conversation, message)
    return false if conditions.blank?

    conditions.all? do |condition|
      match_condition?(condition, conversation, message)
    end
  end

  # Public: evaluate one rule's conditions against a single conversation/message.
  # Builds the per-message target cache that match_condition? relies on, so this
  # can be called standalone (e.g. rule dry-run) without going through execute_for.
  def match_rule?(conditions, conversation, message)
    @target_cache = build_target_cache(conversation, message)
    conditions_match?(conditions, conversation, message)
  end

  private

  # Org-level lookups are built once (memoized) so backfilling one rule over many
  # conversations doesn't re-query tags/members/webhooks per row; the per-row
  # association loads still run so `include?` guards stay accurate.
  def preload_lookups(conversation = nil)
    @tags_by_name ||= @organization.tags.org_wide.index_by(&:name)
    @members_by_key ||= @organization.memberships.index_by(&:key)
    @webhooks_by_key ||= @organization.webhooks.where(enabled: true).index_by(&:key)
    return unless conversation

    conversation.tags.load
    conversation.assignees.load
    conversation.accessible_members.load
  end

  def build_target_cache(conversation, message)
    {
      Rule::FIELD_FROM => message.from_address.to_s.downcase,
      Rule::FIELD_TO => message.to_address.to_s.downcase,
      Rule::FIELD_SUBJECT => conversation.subject.to_s.downcase,
      Rule::FIELD_BODY => message.body_plain.to_s.downcase,
      Rule::FIELD_HAS_ATTACHMENT => message.attachments.any?
    }
  end

  def match_condition?(condition, _conversation, _message)
    field = condition["field"]
    operator = condition["operator"]

    return match_has_attachment?(operator, condition["value"]) if field == Rule::FIELD_HAS_ATTACHMENT

    value = condition["value"].to_s.downcase
    target = @target_cache[field] || ""

    case operator
    when Rule::OPERATOR_EQUALS then target == value
    when Rule::OPERATOR_CONTAINS then target.include?(value)
    when Rule::OPERATOR_STARTS_WITH then target.start_with?(value)
    when Rule::OPERATOR_ENDS_WITH then target.end_with?(value)
    else false
    end
  end

  # The `has_attachment` field is a real boolean, tested with is_true/is_false
  # (or a value-style equals). Mirrors the Rust core's `condition_match`.
  def match_has_attachment?(operator, raw_value)
    present = @target_cache[Rule::FIELD_HAS_ATTACHMENT]
    case operator
    when Rule::OPERATOR_IS_TRUE then present
    when Rule::OPERATOR_IS_FALSE then !present
    when Rule::OPERATOR_EQUALS then (raw_value.to_s == "true") == present
    else false
    end
  end

  # Runs the action list against the conversation, returning the list of actions
  # actually taken (skips no-ops so the run log records real effects). Tag/assign/
  # grant are idempotent via include? guards, which also makes the backfill safe to
  # re-run.
  def apply_actions(actions, conversation)
    return [] if actions.blank?

    taken = []
    actions.each do |action|
      case action["type"]
      when Rule::ACTION_ADD_TAG
        tag = @tags_by_name[action["value"]]
        if tag && !conversation.tags.include?(tag)
          conversation.tags << tag
          taken << "add_tag:#{action['value']}"
        end
      when Rule::ACTION_SET_STATUS
        if Conversation::STATUSES.include?(action["value"]) && conversation.status != action["value"]
          conversation.update!(status: action["value"])
          taken << "set_status:#{action['value']}"
        end
      when Rule::ACTION_ASSIGN
        member = @members_by_key[action["value"]]
        if member && !conversation.assignees.include?(member)
          conversation.assignees << member
          taken << "assign:#{action['value']}"
        end
      when Rule::ACTION_GRANT_ACCESS
        member = @members_by_key[action["value"]]
        if member && !conversation.accessible_members.include?(member)
          conversation.accessible_members << member
          taken << "grant_access:#{action['value']}"
        end
      when Rule::ACTION_WEBHOOK
        taken << "webhook:#{action['value']}" if deliver_webhook(action["value"], conversation)
      end
    end
    taken
  end

  # Enqueue a real HTTP POST to the referenced webhook endpoint (async + retried in
  # WebhookDeliveryJob). Sealed messages carry no server-readable content, so the
  # job sends a metadata-only payload (docs/E2EE.md). Returns true when a delivery
  # was queued (so apply_actions can record it), false for an unknown/disabled key.
  def deliver_webhook(webhook_key, conversation)
    webhook = @webhooks_by_key[webhook_key]
    return false unless webhook

    WebhookDeliveryJob.perform_later(
      webhook.id, conversation.id, @current_message&.id, @current_rule&.id
    )
    true
  end

  # Best-effort run-log write (spec 7.1.5) — never let logging break ingest.
  def log_rule_run(rule, conversation, actions_taken)
    RuleLog.create!(
      rule: rule,
      conversation: conversation,
      result: actions_taken.any? ? "applied" : "matched",
      actions_taken: actions_taken
    )
  rescue => e
    Rails.logger.warn("[RuleExecutor] rule_log write failed: #{e.message}")
  end
end
