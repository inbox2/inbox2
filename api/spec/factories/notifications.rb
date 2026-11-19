FactoryBot.define do
  factory :notification do
    user
    organization
    kind { "assignment" }
    title { "You were assigned" }
    body { "A conversation was assigned to you." }
    read { false }
  end
end
