class MailboxGraphSnapshotSerializer < ::ApplicationSerializer
  attribute :computed_at do |snapshot|
    snapshot.computed_at.iso8601
  end

  attribute :nodes do |snapshot|
    payload = snapshot.payload.is_a?(String) ? JSON.parse(snapshot.payload) : snapshot.payload
    payload["nodes"] || []
  end

  attribute :links do |snapshot|
    payload = snapshot.payload.is_a?(String) ? JSON.parse(snapshot.payload) : snapshot.payload
    payload["links"] || []
  end

  attribute :stats do |snapshot|
    payload = snapshot.payload.is_a?(String) ? JSON.parse(snapshot.payload) : snapshot.payload
    payload["stats"] || {}
  end
end
