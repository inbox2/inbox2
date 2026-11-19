class RuleLogSerializer < ::ApplicationSerializer
  attributes :result, :actions_taken, :created_at

  attribute :conversation_id do |rl|
    rl.conversation&.key
  end
end
