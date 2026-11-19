FactoryBot.define do
  factory :agent do
    organization
    membership
    sequence(:name) { |n| "Agent #{n}" }
    status { Agent::STATUS_ACTIVE }
    permissions { Agent::PERMISSIONS }
    approval_required { false }
  end
end
