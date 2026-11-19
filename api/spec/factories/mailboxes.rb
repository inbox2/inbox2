FactoryBot.define do
  factory :mailbox do
    membership
    domain
    sequence(:local_part) { |n| "mbx#{n}" }
  end
end
