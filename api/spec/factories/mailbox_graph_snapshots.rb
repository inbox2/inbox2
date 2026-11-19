FactoryBot.define do
  factory :mailbox_graph_snapshot do
    organization
    payload { { nodes: [], links: [] }.to_json }
    computed_at { Time.current }
    source_version { "abc123" }
  end
end
