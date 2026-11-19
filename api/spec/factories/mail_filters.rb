FactoryBot.define do
  factory :mail_filter do
    organization
    kind { "blocklist" }
    sequence(:value) { |n| "spammer#{n}@evil.com" }
  end
end
