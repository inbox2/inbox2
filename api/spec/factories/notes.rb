FactoryBot.define do
  factory :note do
    conversation
    organization { conversation.organization }
    membership
    body { "This is an internal note." }
  end
end
