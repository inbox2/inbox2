FactoryBot.define do
  factory :user do
    sequence(:username) { |n| "user#{n}" }
    password { "password123" }
    display_name { "Test User" }
    billing_email { "#{username}@external.com" }
  end
end
