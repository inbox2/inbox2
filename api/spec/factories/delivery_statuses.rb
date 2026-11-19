FactoryBot.define do
  factory :delivery_status do
    message
    status { "queued" }
    attempt_count { 0 }
  end
end
