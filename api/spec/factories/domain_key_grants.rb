FactoryBot.define do
  factory :domain_key_grant do
    domain_key
    membership
    sealed_secret_key { Base64.strict_encode64(SecureRandom.bytes(80)) }
  end
end
