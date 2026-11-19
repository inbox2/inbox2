# Builds the JSON body POSTed to a webhook endpoint when a rule matches.
#
# E2EE: a sealed message has no server-readable content (from/subject/body columns
# are null — docs/E2EE.md), so we emit a metadata-only body for it: ids + receipt
# time + `sealed: true`, and nothing that would leak sealed content. Non-sealed
# messages carry the usual routing/summary fields.
class WebhookPayloadBuilder
  SNIPPET_LIMIT = 280

  def initialize(webhook, conversation, message, rule)
    @webhook = webhook
    @conversation = conversation
    @message = message
    @rule = rule
  end

  def payload
    {
      event: Webhook::EVENT_RULE_MATCHED,
      rule: rule_payload,
      conversation: conversation_payload,
      message: message_payload
    }.compact
  end

  def to_json(*_args)
    payload.to_json
  end

  private

  def rule_payload
    return nil unless @rule

    { id: @rule.key, name: @rule.name }
  end

  def conversation_payload
    return { id: @conversation.key, sealed: true } if sealed?

    { id: @conversation.key, subject: @conversation.subject, status: @conversation.status }
  end

  def message_payload
    return nil unless @message
    return { id: @message.key, sealed: true, received_at: iso(@message.created_at) } if sealed?

    {
      id: @message.key,
      from: @message.from_address,
      to: @message.to_address,
      subject: @message.subject,
      snippet: @message.body_plain&.truncate(SNIPPET_LIMIT),
      received_at: iso(@message.created_at)
    }
  end

  def sealed?
    @message&.sealed?
  end

  def iso(time)
    time&.utc&.iso8601
  end
end
