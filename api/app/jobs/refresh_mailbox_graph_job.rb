class RefreshMailboxGraphJob < ApplicationJob
  queue_as :default

  def perform(organization_id = nil)
    orgs = if organization_id
      Organization.where(id: organization_id)
    else
      Organization.all
    end

    orgs.find_each do |org|
      aggregator = MailboxGraphAggregator.new(org)
      version = aggregator.source_version

      # Skip if snapshot is already current
      existing = org.mailbox_graph_snapshot
      next if existing&.source_version == version

      payload = aggregator.call

      MailboxGraphSnapshot.upsert(
        {
          organization_id: org.id,
          payload: payload.to_json,
          computed_at: Time.current,
          source_version: version,
          key: existing&.key || "mgs_#{Nanoid.generate(size: 21)}",
          created_at: Time.current,
          updated_at: Time.current
        },
        unique_by: :organization_id
      )
    end
  end
end
