class AgentSerializer < ::ApplicationSerializer
  attributes :name, :status, :permissions, :approval_required,
             :rate_limit, :spend_limit_cents, :total_runs, :total_spend_cents,
             :created_at

  one :membership, serializer: MembershipSerializer
end
