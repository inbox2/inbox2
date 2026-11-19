FactoryBot.define do
  factory :oauth_app do
    organization
    sequence(:name) { |n| "Partner App #{n}" }
    redirect_uris { ["https://partner.example.com/callback"] }
  end

  factory :oauth_grant do
    oauth_app
    provider { OauthProvider::GOOGLE }
    redirect_uri { "https://partner.example.com/callback" }
    expires_at { OauthGrant::FLOW_TTL.from_now }
  end
end
