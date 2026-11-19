class SubscriptionSerializer < ::ApplicationSerializer
  attributes :status, :trial_ends_at, :current_period_ends_at

  attribute :plan do |subscription|
    PlanSerializer.new(subscription.plan).to_h if subscription.plan
  end
end
