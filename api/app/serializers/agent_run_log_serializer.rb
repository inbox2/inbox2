class AgentRunLogSerializer < ::ApplicationSerializer
  attributes :action, :status, :duration_ms, :cost_cents, :metadata, :error_message, :created_at

  attribute :conversation_id do |log|
    log.conversation&.key
  end
end
