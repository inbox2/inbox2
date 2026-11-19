FactoryBot.define do
  factory :membership do
    user
    organization
    role { "member" }
    status { "active" }
  end
end
