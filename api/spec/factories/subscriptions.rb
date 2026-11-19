FactoryBot.define do
  factory :subscription do
    organization
    plan
    status { "active" }
    current_period_ends_at { 30.days.from_now }
  end
end
