FactoryBot.define do
  factory :plan do
    sequence(:name) { |n| "Plan #{n}" }
    price_cents { 0 }
    max_domains { 1 }
    max_collaborators { 1 }
    max_message_size_mb { 20 }
    spam_filter { false }
  end
end
