FactoryBot.define do
  factory :delivery_channel do
    organization
    name { "Inbox2 SMTP" }
    kind { "builtin" }
    status { "active" }
    is_default { true }
  end
end
