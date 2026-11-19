FactoryBot.define do
  factory :waitlist_signup do
    sequence(:name) { |n| "Prospect #{n}" }
    sequence(:email) { |n| "prospect#{n}@example.com" }
    company { "Acme Co" }
    industry { "developer" }
    email_services { { "gmail_count" => 2, "office365_count" => 1, "others" => ["Fastmail"] } }
    social_accounts { { "whatsapp_count" => 1, "meta_count" => 0, "messenger_count" => 0, "others" => [] } }

    trait :invited do
      status { WaitlistSignup::STATUS_INVITED }
      invite_token { SecureRandom.urlsafe_base64(32) }
      invited_at { Time.current }
    end
  end
end
