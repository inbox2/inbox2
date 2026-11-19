module Disk
  # params: member_counts ({ share id => count }).
  class ShareSerializer < ::ApplicationSerializer
    attributes :name, :slug, :icon, :color, :openness, :org_role, :archived_at, :trashed_at, :purge_at, :created_at

    attribute :root_node_id do |s|
      s.root_node&.key
    end

    # The team: { id, name } of its domain, or nil for the whole organization.
    attribute :domain do |s|
      s.domain && { id: s.domain.key, name: s.domain.name }
    end

    attribute :sealed do |s|
      s.root_node&.sealed? || false
    end

    attribute :member_count do |s|
      params[:member_counts]&.fetch(s.id, 0) || 0
    end
  end
end
