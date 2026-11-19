class PlanSerializer < ::ApplicationSerializer
  attributes :name, :price_cents, :interval, :max_domains, :max_collaborators,
             :max_message_size_mb, :spam_filter, :e2ee

  attribute :unlimited_domains do |plan|
    plan.unlimited_domains?
  end

  attribute :unlimited_collaborators do |plan|
    plan.unlimited_collaborators?
  end

  # Canonical tier identity (free / paid / max) — clients gate features on this,
  # not on the display name.
  attribute :tier do |plan|
    plan.tier
  end
end
