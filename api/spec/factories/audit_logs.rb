FactoryBot.define do
  factory :audit_log do
    organization
    action { "member.invited" }
    resource_type { "Membership" }
  end
end
