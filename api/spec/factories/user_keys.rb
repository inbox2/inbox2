FactoryBot.define do
  factory :user_key do
    user
    public_key { Base64.strict_encode64(SecureRandom.bytes(32)) }
    encrypted_private_key { Base64.strict_encode64(SecureRandom.bytes(72)) }
    recovery_encrypted_private_key { Base64.strict_encode64(SecureRandom.bytes(72)) }
    kdf_params { { "alg" => "argon2id13", "opslimit" => 3, "memlimit" => 268_435_456 } }
  end
end
