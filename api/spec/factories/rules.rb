FactoryBot.define do
  factory :rule do
    organization
    sequence(:name) { |n| "Rule #{n}" }
    conditions { [{ "field" => "from", "operator" => "contains", "value" => "test" }] }
    actions { [{ "type" => "add_tag", "value" => "auto" }] }
    enabled { true }
    position { 0 }
  end
end
