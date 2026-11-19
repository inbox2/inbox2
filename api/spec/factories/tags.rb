FactoryBot.define do
  factory :tag do
    organization
    sequence(:name) { |n| "tag-#{n}" }
    color { "#6B7280" }
  end
end
