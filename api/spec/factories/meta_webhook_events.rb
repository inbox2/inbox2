FactoryBot.define do
  factory :meta_webhook_event do
    user
    sequence(:provider_event_id) { |n| "sha256:evt-#{n}" }
    object { "whatsapp_business_account" }
    asset_id { "PNID" }
    raw_payload { '{"object":"whatsapp_business_account","entry":[]}' }
    signature_header { "sha256=deadbeef" }
    received_at { Time.current }
  end
end
