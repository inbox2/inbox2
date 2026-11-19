FactoryBot.define do
  factory :esp_key, class: "Esp::Key" do
    organization
    sequence(:name) { |n| "Key #{n}" }
  end

  factory :esp_domain, class: "Esp::Domain" do
    organization
    sequence(:name) { |n| "send#{n}.example" }
    status { Esp::Domain::STATUS_VERIFIED }
  end

  factory :esp_message, class: "Esp::Message" do
    organization
    esp_key { association :esp_key, organization: organization }
    from_address { "app@org.test" }
    to_address { "rcpt@example.com" }
    subject { "Hello" }
    sequence(:message_id_header) { |n| "<m#{n}@org.test>" }
    raw_mime { "Subject: Hello\r\n\r\nbody\r\n" }
  end

  factory :esp_delivery, class: "Esp::Delivery" do
    message factory: :esp_message
    organization { message.organization }
    recipient { "rcpt@example.com" }
  end
end
