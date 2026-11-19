FactoryBot.define do
  factory :message do
    conversation
    organization { conversation.organization }
    from_address { "sender@example.com" }
    to_address { "inbox@team.com" }
    subject { "Test message" }
    body_plain { "Hello, this is a test message." }
    content_type { "text/plain" }
    is_inbound { true }
    is_draft { false }
    sequence(:message_id_header) { |n| "<msg-#{n}@example.com>" }
  end
end
