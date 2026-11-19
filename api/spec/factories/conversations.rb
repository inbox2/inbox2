FactoryBot.define do
  factory :conversation do
    organization
    subject { "Test conversation" }
    status { "open" }
    snippet { "Hello, this is a test..." }
    from_address { "sender@example.com" }
    to_address { "inbox@team.com" }
  end
end
