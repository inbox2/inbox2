FactoryBot.define do
  factory :view do
    organization
    sequence(:name) { |n| "View #{n}" }
    kind { "personal" }
    filters { [{ "field" => "status", "operator" => "equals", "value" => "open" }] }
    position { 0 }
  end
end
