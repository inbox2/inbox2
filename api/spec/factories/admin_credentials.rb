FactoryBot.define do
  factory :admin_credential do
    sequence(:label) { |n| "operator-#{n}" }
    # 64 lowercase hex chars (a SHA-256 fingerprint), unique per record.
    sequence(:cert_fingerprint) { |n| format("%064x", n + 0xabc123) }
    email { "ops@inbox2.com" }
  end
end
