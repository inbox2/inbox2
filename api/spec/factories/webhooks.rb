FactoryBot.define do
  factory :webhook do
    organization
    url { "https://example.com/webhook" }
    enabled { true }
  end
end
