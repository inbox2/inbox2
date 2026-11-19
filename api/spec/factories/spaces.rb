FactoryBot.define do
  factory :space do
    organization
    sequence(:name) { |n| "Space #{n}" }
    sequence(:slug) { |n| "space-#{n}" }
    icon { "globe" }
    openness { "assigned" }
    classify { true }
    position { 0 }
  end
end
