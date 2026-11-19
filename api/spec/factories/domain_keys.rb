FactoryBot.define do
  factory :domain_key do
    domain
    version { 1 }
    public_key { Base64.strict_encode64(SecureRandom.bytes(32)) }
  end
end
