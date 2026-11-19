FactoryBot.define do
  factory :domain do
    sequence(:name) { |n| "domain#{n}.test" }
    organization
    status { "verified" }
  end
end
